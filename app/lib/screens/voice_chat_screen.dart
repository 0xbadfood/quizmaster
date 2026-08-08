import 'dart:async';
import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../voice/audio_bridge.dart';
import '../voice/local_pocket_tts.dart';
import '../voice/local_whisper_asr.dart';
import '../voice/story_wizard_assets.dart';
import '../voice/talk_voice_preferences.dart';

const String _defaultServerUrl = 'https://voice.photovault.live';
const String _appBackgroundAsset = 'assets/images/bg_sunshine_world.png';
const bool _diagnosticsEnabled = bool.fromEnvironment(
  'STORYVAULT_DIAGNOSTICS',
  defaultValue: false,
);
const double _personaPortraitAspectRatio = 0.64;
const Duration _noiseCalibrationWindow = Duration(milliseconds: 350);
const double _defaultFirstVoiceWaitSeconds = 5;
const double _defaultEndWaitSeconds = 2;
const double _minFirstVoiceWaitSeconds = 1;
const double _maxFirstVoiceWaitSeconds = 10;
const double _minEndWaitSeconds = 0.4;
const double _maxEndWaitSeconds = 4;
const Duration _maxUtteranceDuration = Duration(seconds: 12);
const Duration _connectedIdleTimeout = Duration(minutes: 3);
const int _preSpeechBufferMs = 500;
const int _voiceStartFrames = 5;
const double _voiceRmsThreshold = 0.008;
const double _voicePeakThreshold = 0.03;
const double _voiceMinZeroCrossingRate = 0.004;
const double _voiceMaxZeroCrossingRate = 0.35;
const double _voiceNoiseRmsMultiplier = 1.45;
const double _voiceNoiseRmsMargin = 0.006;
const double _noiseFloorRiseAlpha = 0.015;
const double _noiseFloorFallAlpha = 0.35;
const int _assistantPlaybackDoneCushionMs = 180;
const int _localTtsPlaybackTailMs = 850;
const int _localTtsInterChunkPauseMs = 600;
const int _wizardStoryCommaPauseMs = 260;
const int _wizardStorySentencePauseMs = 700;
const int _wizardStoryParagraphPauseMs = 1200;
const int _wizardStoryForcedSplitPauseMs = 700;
const int _localTtsPlaybackDrainTimeoutMs = 45000;
const int _localTtsMicSettleMs = 300;
const int _localTtsFirstSentenceMinChars = 60;
const int _localTtsFirstChunkMaxChars = 120;
const int _localTtsNextSentenceMinChars = 50;
const int _localTtsNextChunkMaxChars = 260;
const int _localTtsHardChunkMaxChars = 340;
const int _localTtsStartupFallbackChars = 45;
const int _wizardStoryPhraseTargetChars = 520;
const int _wizardStoryPhraseHardMaxChars = 820;
const int _diagnosticChunkLogMaxChars = 2400;
const int _diagnosticFullTextMaxChars = 1800;
const int _diagnosticSheetTextMaxChars = 5000;
const int _diagnosticCardTextMaxChars = 900;
const Duration _localTtsStartupFallbackWait = Duration(milliseconds: 650);

enum CallPhase {
  disconnected,
  connecting,
  ready,
  listening,
  thinking,
  speaking,
}

class _LocalTtsChunk {
  const _LocalTtsChunk({
    required this.id,
    required this.text,
    required this.hash,
    required this.subtitleWordCount,
    this.pauseAfterMs = _localTtsInterChunkPauseMs,
  });

  final int id;
  final String text;
  final String hash;
  final int subtitleWordCount;
  final int pauseAfterMs;
}

class _WizardStoryTtsUnit {
  const _WizardStoryTtsUnit({required this.text, required this.pauseAfterMs});

  final String text;
  final int pauseAfterMs;
}

class _LiveSubtitleSegment {
  _LiveSubtitleSegment({
    required this.chunkId,
    required this.text,
    required this.wordCount,
    required this.startMs,
    required this.durationMs,
  });

  final int chunkId;
  final String text;
  final int wordCount;
  int startMs;
  int durationMs;

  int get endMs => startMs + durationMs;
}

class _SanitizedTtsText {
  const _SanitizedTtsText({
    required this.text,
    required this.removedCodePoints,
  });

  final String text;
  final int removedCodePoints;
}

String _formatBytes(int bytes) {
  if (bytes < 1024) {
    return '$bytes B';
  }
  final double kb = bytes / 1024;
  if (kb < 1024) {
    return '${kb.toStringAsFixed(1)} KB';
  }
  return '${(kb / 1024).toStringAsFixed(1)} MB';
}

String _formatSeconds(double seconds) {
  if ((seconds - seconds.round()).abs() < 0.01) {
    return seconds.round().toString();
  }
  return seconds.toStringAsFixed(1);
}

extension CallPhaseView on CallPhase {
  String get label {
    return switch (this) {
      CallPhase.disconnected => 'Disconnected',
      CallPhase.connecting => 'Connecting',
      CallPhase.ready => 'Ready',
      CallPhase.listening => 'Listening',
      CallPhase.thinking => 'Thinking',
      CallPhase.speaking => 'Speaking',
    };
  }

  Color get color {
    return switch (this) {
      CallPhase.disconnected => const Color(0xFFD84A4A),
      CallPhase.connecting => const Color(0xFF7A8393),
      CallPhase.ready => const Color(0xFF209B67),
      CallPhase.listening => const Color(0xFFF2A23A),
      CallPhase.thinking => const Color(0xFF4E79B8),
      CallPhase.speaking => const Color(0xFF6C5CE7),
    };
  }

  IconData get icon {
    return switch (this) {
      CallPhase.disconnected => Icons.call,
      CallPhase.connecting => Icons.sync,
      CallPhase.ready => Icons.mic,
      CallPhase.listening => Icons.stop,
      CallPhase.thinking => Icons.hourglass_top,
      CallPhase.speaking => Icons.graphic_eq,
    };
  }
}

class PersonaProfile {
  const PersonaProfile({
    required this.id,
    required this.displayName,
    required this.subtitle,
    required this.tagline,
    required this.color,
    required this.format,
    required this.path,
    required this.thumbnailUrl,
    required this.portraitUrl,
    required this.assetVersion,
    this.voiceSampleUrl = '',
    this.voiceAssetSha256 = '',
    this.voiceLibraryId = '',
    this.voiceLibraryName = '',
    this.cachedThumbnailPath,
    this.cachedPortraitPath,
    this.cachedVoiceSamplePath,
  });

  factory PersonaProfile.fromJson(Map<String, dynamic> json) {
    final String id =
        (json['id'] as String?) ?? (json['name'] as String?) ?? 'spark';
    final String voiceAssetSha256 =
        (json['voice_asset_sha256'] as String?) ?? '';
    final String voiceSampleUrl =
        (json['voice_sample_url'] as String?) ??
        (voiceAssetSha256.isNotEmpty
            ? '/api/tts-assets/personas/$id/voice-sample'
            : '');
    return PersonaProfile(
      id: id,
      displayName:
          (json['display_name'] as String?) ?? PersonaVisual.titleFromId(id),
      subtitle: (json['subtitle'] as String?) ?? 'Guide',
      tagline: (json['tagline'] as String?) ?? 'A voice persona.',
      color: _colorFromHex((json['color'] as String?) ?? '#1A5ABF'),
      format: (json['format'] as String?) ?? '',
      path: (json['path'] as String?) ?? '',
      thumbnailUrl: (json['thumbnail_url'] as String?) ?? '',
      portraitUrl: (json['portrait_url'] as String?) ?? '',
      assetVersion: (json['asset_version'] as String?) ?? '0',
      voiceSampleUrl: voiceSampleUrl,
      voiceAssetSha256: voiceAssetSha256,
      voiceLibraryId: (json['voice_library_id'] as String?) ?? '',
      voiceLibraryName: (json['voice_library_name'] as String?) ?? '',
    );
  }

  final String id;
  final String displayName;
  final String subtitle;
  final String tagline;
  final Color color;
  final String format;
  final String path;
  final String thumbnailUrl;
  final String portraitUrl;
  final String assetVersion;
  final String voiceSampleUrl;
  final String voiceAssetSha256;
  final String voiceLibraryId;
  final String voiceLibraryName;
  final String? cachedThumbnailPath;
  final String? cachedPortraitPath;
  final String? cachedVoiceSamplePath;

  String get name => id;

  String get voiceCacheKey {
    final String hash = voiceAssetSha256.trim();
    if (hash.isNotEmpty) {
      return hash;
    }
    final String libraryId = voiceLibraryId.trim();
    if (libraryId.isNotEmpty) {
      return '${libraryId}_$assetVersion';
    }
    return assetVersion;
  }

  PersonaProfile copyWith({
    String? cachedThumbnailPath,
    String? cachedPortraitPath,
    String? cachedVoiceSamplePath,
  }) {
    return PersonaProfile(
      id: id,
      displayName: displayName,
      subtitle: subtitle,
      tagline: tagline,
      color: color,
      format: format,
      path: path,
      thumbnailUrl: thumbnailUrl,
      portraitUrl: portraitUrl,
      assetVersion: assetVersion,
      voiceSampleUrl: voiceSampleUrl,
      voiceAssetSha256: voiceAssetSha256,
      voiceLibraryId: voiceLibraryId,
      voiceLibraryName: voiceLibraryName,
      cachedThumbnailPath: cachedThumbnailPath ?? this.cachedThumbnailPath,
      cachedPortraitPath: cachedPortraitPath ?? this.cachedPortraitPath,
      cachedVoiceSamplePath:
          cachedVoiceSamplePath ?? this.cachedVoiceSamplePath,
    );
  }
}

class TalkWizardSummary {
  const TalkWizardSummary({
    required this.wizardId,
    required this.personaId,
    required this.title,
    required this.description,
  });

  factory TalkWizardSummary.fromJson(Map<String, dynamic> json) {
    final String wizardId = (json['wizard_id'] as String?) ?? '';
    return TalkWizardSummary(
      wizardId: wizardId,
      personaId: (json['persona_id'] as String?) ?? wizardId,
      title: (json['title'] as String?) ?? PersonaVisual.titleFromId(wizardId),
      description: (json['description'] as String?) ?? '',
    );
  }

  final String wizardId;
  final String personaId;
  final String title;
  final String description;
}

class TalkWizardIntro {
  const TalkWizardIntro({
    required this.prompt,
    required this.skipLabel,
    required this.skipAllowed,
    required this.seenStorageKey,
  });

  factory TalkWizardIntro.fromJson(Map<String, dynamic>? json) {
    if (json == null) {
      return const TalkWizardIntro(
        prompt: '',
        skipLabel: 'Begin',
        skipAllowed: false,
        seenStorageKey: '',
      );
    }
    return TalkWizardIntro(
      prompt: (json['prompt'] as String?) ?? '',
      skipLabel: (json['skip_label'] as String?) ?? 'Begin',
      skipAllowed: (json['skip_allowed'] as bool?) ?? false,
      seenStorageKey: (json['seen_storage_key'] as String?) ?? '',
    );
  }

  final String prompt;
  final String skipLabel;
  final bool skipAllowed;
  final String seenStorageKey;
}

class TalkWizardChoice {
  const TalkWizardChoice({
    required this.choiceId,
    required this.label,
    required this.imageHint,
    required this.imageAssetPath,
    required this.imageUrl,
  });

  factory TalkWizardChoice.fromJson(Map<String, dynamic> json) {
    return TalkWizardChoice(
      choiceId: (json['choice_id'] as String?) ?? '',
      label: (json['label'] as String?) ?? '',
      imageHint: (json['image_hint'] as String?) ?? '',
      imageAssetPath:
          (json['image_asset_path'] as String?) ??
          (json['asset_path'] as String?) ??
          '',
      imageUrl: (json['image_url'] as String?) ?? '',
    );
  }

  final String choiceId;
  final String label;
  final String imageHint;
  final String imageAssetPath;
  final String imageUrl;
}

class TalkWizardState {
  const TalkWizardState({
    required this.stateId,
    required this.stepIndex,
    required this.slot,
    required this.prompt,
    required this.spokenPrompt,
    required this.choices,
  });

  factory TalkWizardState.fromJson(Map<String, dynamic> json) {
    return TalkWizardState(
      stateId: (json['state_id'] as String?) ?? '',
      stepIndex: (json['step_index'] as num?)?.toInt() ?? 0,
      slot: (json['slot'] as String?) ?? '',
      prompt: (json['prompt'] as String?) ?? '',
      spokenPrompt: (json['spoken_prompt'] as String?) ?? '',
      choices: ((json['choices'] as List<dynamic>?) ?? const <dynamic>[])
          .whereType<Map<String, dynamic>>()
          .map(TalkWizardChoice.fromJson)
          .where((TalkWizardChoice choice) => choice.choiceId.isNotEmpty)
          .toList(growable: false),
    );
  }

  final String stateId;
  final int stepIndex;
  final String slot;
  final String prompt;
  final String spokenPrompt;
  final List<TalkWizardChoice> choices;
}

class PersonaVisual {
  const PersonaVisual({
    required this.id,
    required this.displayName,
    required this.subtitle,
    required this.assetPath,
    required this.color,
    required this.tagline,
    this.thumbnailFilePath,
    this.portraitFilePath,
  });

  final String id;
  final String displayName;
  final String subtitle;
  final String assetPath;
  final Color color;
  final String tagline;
  final String? thumbnailFilePath;
  final String? portraitFilePath;

  String get fullName => '$displayName $subtitle';

  static const List<PersonaVisual> all = <PersonaVisual>[
    PersonaVisual(
      id: 'spark',
      displayName: 'Spark',
      subtitle: 'Wonder Wizard',
      assetPath: 'assets/personas/wizard_wonder.png',
      color: Color(0xFF1A5ABF),
      tagline: 'Curious facts, tiny stories, and bright questions.',
    ),
    PersonaVisual(
      id: 'story',
      displayName: 'Story',
      subtitle: 'Wizard',
      assetPath: 'assets/personas/wizard_story.png',
      color: Color(0xFFE8871A),
      tagline: 'A cozy guide for make-believe adventures.',
    ),
    PersonaVisual(
      id: 'sleepy',
      displayName: 'Sleepy',
      subtitle: 'Wizard',
      assetPath: 'assets/personas/wizard_sleepy.png',
      color: Color(0xFF1A3A8F),
      tagline: 'Soft bedtime tales and moonlit questions.',
    ),
    PersonaVisual(
      id: 'animal',
      displayName: 'Animal',
      subtitle: 'Wizard',
      assetPath: 'assets/personas/wizard_animal.png',
      color: Color(0xFF2D7A2D),
      tagline: 'Wild facts, creature quests, and jungle fun.',
    ),
    PersonaVisual(
      id: 'adventure',
      displayName: 'Adventure',
      subtitle: 'Wizard',
      assetPath: 'assets/personas/wizard_adventure.png',
      color: Color(0xFFC0392B),
      tagline: 'Bold quests with choices around every corner.',
    ),
    PersonaVisual(
      id: 'wisdom',
      displayName: 'Wisdom',
      subtitle: 'Wizard',
      assetPath: 'assets/personas/wizard_wisdom.png',
      color: Color(0xFF6B2FA0),
      tagline: 'Gentle riddles, old tales, and clever answers.',
    ),
  ];

  static PersonaVisual forPersonaName(String? name) {
    if (name == null || name.isEmpty) {
      return all.first;
    }
    for (final PersonaVisual visual in all) {
      if (visual.id == name) {
        return visual;
      }
    }
    return PersonaVisual(
      id: name,
      displayName: titleFromId(name),
      subtitle: 'Guide',
      assetPath: 'assets/personas/wizard_wonder.png',
      color: const Color(0xFF1A5ABF),
      tagline: 'A custom voice persona.',
    );
  }

  static PersonaVisual forPersona(PersonaProfile persona) {
    final PersonaVisual fallback = forPersonaName(persona.id);
    return PersonaVisual(
      id: persona.id,
      displayName: persona.displayName,
      subtitle: persona.subtitle,
      assetPath: fallback.assetPath,
      color: persona.color,
      tagline: persona.tagline,
      thumbnailFilePath: persona.cachedThumbnailPath,
      portraitFilePath: persona.cachedPortraitPath,
    );
  }

  ImageProvider<Object> imageProvider({bool portrait = false}) {
    final String? filePath = portrait
        ? portraitFilePath ?? thumbnailFilePath
        : thumbnailFilePath ?? portraitFilePath;
    if (filePath != null && filePath.isNotEmpty) {
      return FileImage(File(filePath));
    }
    return AssetImage(assetPath);
  }

  static String titleFromId(String id) {
    final List<String> words = id
        .replaceAll('-', ' ')
        .replaceAll('_', ' ')
        .split(' ')
        .where((String word) => word.isNotEmpty)
        .toList();
    if (words.isEmpty) {
      return 'Persona';
    }
    return words
        .map(
          (String word) => word.length == 1
              ? word.toUpperCase()
              : '${word[0].toUpperCase()}${word.substring(1)}',
        )
        .join(' ');
  }
}

Color _colorFromHex(String raw) {
  final String normalized = raw.trim().replaceFirst('#', '');
  if (normalized.length != 6) {
    return const Color(0xFF1A5ABF);
  }
  final int? rgb = int.tryParse(normalized, radix: 16);
  if (rgb == null) {
    return const Color(0xFF1A5ABF);
  }
  return Color(0xFF000000 | rgb);
}

class _MicFrameStats {
  const _MicFrameStats({
    required this.level,
    required this.isHumanVoice,
    required this.rms,
    required this.peak,
    required this.zeroCrossingRate,
  });

  final double level;
  final bool isHumanVoice;
  final double rms;
  final double peak;
  final double zeroCrossingRate;
}

class _FadTimingSettings {
  const _FadTimingSettings({
    required this.firstVoiceWaitSeconds,
    required this.endWaitSeconds,
  });

  final double firstVoiceWaitSeconds;
  final double endWaitSeconds;
}

class VoiceChatScreen extends StatefulWidget {
  const VoiceChatScreen({
    required this.enableLocalVoice,
    this.localTtsNumThreads = 2,
    super.key,
  });

  final bool enableLocalVoice;
  final int localTtsNumThreads;

  @override
  State<VoiceChatScreen> createState() => _VoiceChatScreenState();
}

class _VoiceChatScreenState extends State<VoiceChatScreen> {
  final SparkAudioBridge _audio = SparkAudioBridge();
  late final LocalPocketTts _localPocketTts = LocalPocketTts(
    _audio,
    numThreads: widget.localTtsNumThreads,
  );
  final LocalWhisperAsr _localWhisperAsr = const LocalWhisperAsr();
  final TextEditingController _serverController = TextEditingController(
    text: _defaultServerUrl,
  );
  final TextEditingController _textController = TextEditingController();
  final ScrollController _transcriptScrollController = ScrollController();

  WebSocket? _socket;
  StreamSubscription<dynamic>? _socketSubscription;
  StreamSubscription<SparkMicFrame>? _micSubscription;
  Timer? _recordingWatchTimer;
  Timer? _assistantPlaybackDoneTimer;
  Timer? _listeningTimeoutTimer;
  Timer? _connectedIdleTimer;
  Timer? _subtitleHighlightTimer;
  Completer<void>? _localTtsQueueSignal;
  Future<void>? _localTtsDrainFuture;

  List<PersonaProfile> _personas = const [];
  List<TalkWizardSummary> _wizards = const [];
  PersonaProfile? _selectedPersona;
  String? _wizardSessionId;
  TalkWizardIntro? _wizardIntro;
  TalkWizardState? _wizardState;
  CallPhase _phase = CallPhase.disconnected;
  String _status = 'Disconnected';
  String _wizardStatus = '';
  String _lastUserText = '';
  String _assistantText = '';
  String _assistantDraft = '';
  String _wizardStoryText = '';
  String _activeWizardId = '';
  final List<String> _events = <String>[];
  final Map<String, Object?> _metrics = <String, Object?>{};

  int _inputSampleRate = 16000;
  int _outputSampleRate = 24000;
  int _frameMs = 20;
  int _eventCount = 0;
  int _micBytes = 0;
  int _micFramesSent = 0;
  int _listenStartMicBytes = 0;
  int _listenStartMicFrames = 0;
  int _listenStartedAtMs = 0;
  int _lastMicFrameAtMs = 0;
  int _lastVoiceAtMs = 0;
  int _voiceStartedAtMs = 0;
  int _voiceFrameStreak = 0;
  int _noiseFloorFrames = 0;
  int _preSpeechBytes = 0;
  int _nativeMicBytes = 0;
  int _nativeMicFrames = 0;
  int _audioBytes = 0;
  int _assistantPlaybackGeneration = 0;
  int _localTtsSpeakRequestId = 0;
  int _lastLocalTtsStartedAtMs = 0;
  int _assistantPlaybackEndsAtMs = 0;
  int _localTtsStreamGeneration = 0;
  int _localTtsFirstTokenAtMs = 0;
  int _localTtsChunkSequence = 0;
  int _localTtsChunksSpoken = 0;
  int _localTtsStreamBytes = 0;
  int _localTtsStreamChunks = 0;
  int _localTtsPauseChunks = 0;
  int _localTtsPauseBytes = 0;
  int _localTtsPlaybackSessionId = 0;
  int _localTtsSubtitleCursorMs = 0;
  int _liveSubtitleActiveWordIndex = -1;
  int _liveSubtitleGeneration = 0;
  int _liveSubtitleChunkId = 0;
  int _micFrameUiCounter = 0;
  int _pocketTtsSanitizedRemovedTotal = 0;
  double _firstVoiceWaitSeconds = _defaultFirstVoiceWaitSeconds;
  double _endWaitSeconds = _defaultEndWaitSeconds;
  double _micLevel = 0;
  double _noiseRmsFloor = 0;
  double _noisePeakFloor = 0;
  double _talkVoiceSpeed = talkVoiceSpeedDefault;
  int _talkVoicePrerollMs = talkVoicePrerollDefaultMs;
  TalkVoiceChunkBoundary _talkVoiceChunkBoundary =
      talkVoiceChunkBoundaryDefault;
  String _nativeAudioSource = '';
  String _nativeVadSource = '';
  String _nativeVadMode = '';
  String _ttsMode = 'client_text';
  String _lastLocalTtsTextHash = '';
  String _localTtsStreamBuffer = '';
  String _pocketTtsQueuedChunkLog = '';
  String _pocketTtsFullQueuedInput = '';
  String _pocketTtsSpokenChunkLog = '';
  String _pocketTtsFullSpokenInput = '';
  String _liveAudioCaption = '';
  String _liveSubtitleText = '';
  String? _talkTextLogPath;
  String? _pendingCallPersonaName;
  String? _callPersonaName;

  bool _loadingPersonas = false;
  bool _personaManifestLoaded = false;
  bool _welcomeSent = false;
  bool _waitingForGeneratedWelcome = false;
  bool _wizardIntroFinished = false;
  bool _wizardBusy = false;
  bool _wizardGeneratingStory = false;
  bool _wizardQuestionsStarted = false;
  bool _turnRunning = false;
  bool _disconnecting = false;
  bool _autoListenEnabled = false;
  bool _sessionStartAcknowledged = false;
  bool _voiceStarted = false;
  bool _listeningStopRequested = false;
  bool _localTtsQueueRunning = false;
  bool _localTtsStreamFinal = false;
  final List<Uint8List> _preSpeechFrames = <Uint8List>[];
  final List<Uint8List> _localSpeechFrames = <Uint8List>[];
  final List<Uint8List> _localFallbackFrames = <Uint8List>[];
  final List<_LocalTtsChunk> _localTtsQueue = <_LocalTtsChunk>[];
  final List<_LiveSubtitleSegment> _liveSubtitleSchedule =
      <_LiveSubtitleSegment>[];
  final Set<String> _localTtsChunkHashes = <String>{};
  int _localFallbackBytes = 0;

  bool get _isConnected => _socket != null;
  String get _preferredTtsMode => 'client_text';
  bool get _usesLocalPocketTts =>
      widget.enableLocalVoice &&
      (Platform.isIOS || Platform.isAndroid) &&
      _ttsMode == 'client_text';
  bool get _usesDeviceAsrForTurn => _usesLocalPocketTts;
  int _llmRequestGeneration = 0;

  Duration get _firstVoiceTimeout =>
      Duration(milliseconds: (_firstVoiceWaitSeconds * 1000).round());

  Duration get _postVoiceSilenceTimeout =>
      Duration(milliseconds: (_endWaitSeconds * 1000).round());

  List<PersonaVisual> get _availableVisuals {
    if (_personas.isEmpty) {
      if (!_personaManifestLoaded || _loadingPersonas) {
        return const <PersonaVisual>[];
      }
      return <PersonaVisual>[PersonaVisual.forPersonaName('spark')];
    }
    return _personas.map(PersonaVisual.forPersona).toList();
  }

  PersonaVisual get _selectedVisual {
    final PersonaProfile? selected = _selectedPersona;
    if (selected != null) {
      return PersonaVisual.forPersona(selected);
    }
    final List<PersonaVisual> visuals = _availableVisuals;
    return visuals.isEmpty
        ? PersonaVisual.forPersonaName('spark')
        : visuals.first;
  }

  PersonaVisual get _callVisual {
    final String? personaId =
        _callPersonaName ?? _pendingCallPersonaName ?? _selectedPersona?.name;
    final PersonaProfile? persona = _firstWhereOrNull(
      _personas,
      (PersonaProfile item) => item.name == personaId,
    );
    return persona == null
        ? PersonaVisual.forPersonaName(personaId)
        : PersonaVisual.forPersona(persona);
  }

  @override
  void initState() {
    super.initState();
    unawaited(_loadTalkVoiceSpeedPreference());
    unawaited(_loadTalkVoicePrerollPreference());
    unawaited(_loadTalkVoiceChunkBoundaryPreference());
    Future<void>.microtask(_loadPersonas);
  }

  Future<void> _loadTalkVoiceSpeedPreference() async {
    final double speed = await loadTalkVoiceSpeed();
    if (!mounted) {
      return;
    }
    setState(() {
      _talkVoiceSpeed = speed;
    });
  }

  Future<void> _loadTalkVoicePrerollPreference() async {
    final int prerollMs = await loadTalkVoicePrerollMs();
    if (!mounted) {
      return;
    }
    setState(() {
      _talkVoicePrerollMs = prerollMs;
    });
  }

  Future<void> _loadTalkVoiceChunkBoundaryPreference() async {
    final TalkVoiceChunkBoundary boundary = await loadTalkVoiceChunkBoundary();
    if (!mounted) {
      return;
    }
    setState(() {
      _talkVoiceChunkBoundary = boundary;
    });
  }

  Future<double> _currentTalkVoiceSpeed() async {
    final double speed = await loadTalkVoiceSpeed();
    if (mounted && speed != _talkVoiceSpeed) {
      setState(() {
        _talkVoiceSpeed = speed;
      });
    }
    return speed;
  }

  Future<int> _currentTalkVoicePrerollMs() async {
    final int prerollMs = await loadTalkVoicePrerollMs();
    if (mounted && prerollMs != _talkVoicePrerollMs) {
      setState(() {
        _talkVoicePrerollMs = prerollMs;
      });
    }
    return prerollMs;
  }

  Future<TalkVoiceChunkBoundary> _currentTalkVoiceChunkBoundary() async {
    final TalkVoiceChunkBoundary boundary = await loadTalkVoiceChunkBoundary();
    if (mounted && boundary != _talkVoiceChunkBoundary) {
      setState(() {
        _talkVoiceChunkBoundary = boundary;
      });
    }
    return boundary;
  }

  @override
  void dispose() {
    _recordingWatchTimer?.cancel();
    _assistantPlaybackDoneTimer?.cancel();
    _listeningTimeoutTimer?.cancel();
    _connectedIdleTimer?.cancel();
    _subtitleHighlightTimer?.cancel();
    _socketSubscription?.cancel();
    _micSubscription?.cancel();
    _socket?.close();
    _audio.stopRecording();
    _audio.stopPlayback();
    unawaited(_localPocketTts.dispose());
    _serverController.dispose();
    _textController.dispose();
    _transcriptScrollController.dispose();
    super.dispose();
  }

  Future<void> _loadPersonas({String? preferredPersonaName}) async {
    if (_loadingPersonas) {
      return;
    }
    final String? currentPersonaName =
        preferredPersonaName ?? _selectedPersona?.name;
    final Uri? baseUri = _baseUri();
    if (baseUri == null) {
      _setStatus('Invalid server URL');
      return;
    }

    setState(() {
      _loadingPersonas = true;
    });

    final HttpClient client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 3);
    try {
      final Uri personasUri = _backendUri('/api/personas', baseUri)!;
      final HttpClientRequest request = await client.getUrl(personasUri);
      final HttpClientResponse response = await request.close();
      final String body = await response.transform(utf8.decoder).join();
      if (response.statusCode != HttpStatus.ok) {
        throw HttpException('HTTP ${response.statusCode}: $body');
      }

      final Map<String, dynamic> decoded =
          jsonDecode(body) as Map<String, dynamic>;
      final List<PersonaProfile> fetchedPersonas =
          ((decoded['personas'] as List<dynamic>?) ?? const <dynamic>[])
              .whereType<Map<String, dynamic>>()
              .map(PersonaProfile.fromJson)
              .toList();
      final List<PersonaProfile> personas = await _cachePersonaAssets(
        fetchedPersonas,
        baseUri,
      );
      final List<TalkWizardSummary> wizards = await _fetchTalkWizards(
        client,
        baseUri,
      );
      final String? active = decoded['active'] as String?;

      if (!mounted) {
        return;
      }
      setState(() {
        _personas = personas;
        _wizards = wizards;
        _selectedPersona =
            _firstWhereOrNull(
              personas,
              (PersonaProfile persona) => persona.name == currentPersonaName,
            ) ??
            _firstWhereOrNull(
              personas,
              (PersonaProfile persona) => persona.name == active,
            );
        _selectedPersona ??= personas.isNotEmpty ? personas.first : null;
        _status = _phase.label;
      });
      _log(
        'Loaded ${personas.length} persona profile(s), '
        '${wizards.length} wizard profile(s)',
      );
    } catch (error) {
      _log('Persona load failed: $error');
      if (mounted) {
        setState(() {
          _personaManifestLoaded = true;
          _selectedPersona ??= const PersonaProfile(
            id: 'spark',
            displayName: 'Spark',
            subtitle: 'Wonder Wizard',
            tagline: 'Curious facts, tiny stories, and bright questions.',
            color: Color(0xFF1A5ABF),
            format: 'txt',
            path: '',
            thumbnailUrl: '',
            portraitUrl: '',
            assetVersion: '0',
          );
        });
      }
    } finally {
      client.close(force: true);
      if (mounted) {
        setState(() {
          _personaManifestLoaded = true;
          _loadingPersonas = false;
        });
      }
    }
  }

  Future<List<TalkWizardSummary>> _fetchTalkWizards(
    HttpClient client,
    Uri baseUri,
  ) async {
    try {
      final Uri wizardsUri = _backendUri('/api/talk/wizards', baseUri)!;
      final HttpClientRequest request = await client.getUrl(wizardsUri);
      final HttpClientResponse response = await request.close();
      final String body = await response.transform(utf8.decoder).join();
      if (response.statusCode != HttpStatus.ok) {
        throw HttpException('HTTP ${response.statusCode}: $body');
      }
      final Map<String, dynamic> decoded =
          jsonDecode(body) as Map<String, dynamic>;
      return ((decoded['wizards'] as List<dynamic>?) ?? const <dynamic>[])
          .whereType<Map<String, dynamic>>()
          .map(TalkWizardSummary.fromJson)
          .where((TalkWizardSummary wizard) => wizard.wizardId.isNotEmpty)
          .toList(growable: false);
    } catch (error) {
      _log('Wizard manifest load failed: $error');
      return const <TalkWizardSummary>[];
    }
  }

  Future<List<PersonaProfile>> _cachePersonaAssets(
    List<PersonaProfile> personas,
    Uri baseUri,
  ) async {
    if (personas.isEmpty) {
      return personas;
    }
    Directory cacheDir;
    try {
      final Directory documents = await getApplicationDocumentsDirectory();
      cacheDir = Directory('${documents.path}/persona_cache');
      if (!await cacheDir.exists()) {
        await cacheDir.create(recursive: true);
      }
    } catch (error) {
      _log('Persona image cache unavailable: $error');
      return personas;
    }

    final HttpClient client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 5);
    try {
      final List<PersonaProfile> cached = <PersonaProfile>[];
      for (final PersonaProfile persona in personas) {
        final String? thumbnailPath = await _cachePersonaImage(
          client,
          cacheDir: cacheDir,
          baseUri: baseUri,
          persona: persona,
          url: persona.thumbnailUrl,
          kind: 'thumbnail',
        );
        final String? portraitPath = await _cachePersonaImage(
          client,
          cacheDir: cacheDir,
          baseUri: baseUri,
          persona: persona,
          url: persona.portraitUrl,
          kind: 'portrait',
        );
        final String? voiceSamplePath = await _cachePersonaVoiceSample(
          client,
          cacheDir: cacheDir,
          baseUri: baseUri,
          persona: persona,
        );
        cached.add(
          persona.copyWith(
            cachedThumbnailPath: thumbnailPath,
            cachedPortraitPath: portraitPath,
            cachedVoiceSamplePath: voiceSamplePath,
          ),
        );
      }
      return cached;
    } finally {
      client.close(force: true);
    }
  }

  Future<String?> _cachePersonaImage(
    HttpClient client, {
    required Directory cacheDir,
    required Uri baseUri,
    required PersonaProfile persona,
    required String url,
    required String kind,
  }) async {
    if (url.isEmpty) {
      return null;
    }
    final Uri? imageUri = _backendUri(url, baseUri);
    if (imageUri == null) {
      return null;
    }
    final String token = _safeCacheToken(
      '${persona.id}_${persona.assetVersion}_$kind',
    );
    final File file = File('${cacheDir.path}/$token.img');
    if (await file.exists() && await file.length() > 0) {
      return file.path;
    }
    try {
      final HttpClientRequest request = await client.getUrl(imageUri);
      final HttpClientResponse response = await request.close();
      if (response.statusCode != HttpStatus.ok) {
        return null;
      }
      final Uint8List bytes = Uint8List.fromList(
        await response.expand((List<int> chunk) => chunk).toList(),
      );
      if (bytes.isEmpty) {
        return null;
      }
      await file.writeAsBytes(bytes, flush: true);
      return file.path;
    } catch (error) {
      _log('Persona image fetch failed for ${persona.id}: $error');
      return null;
    }
  }

  Future<String?> _cachePersonaVoiceSample(
    HttpClient client, {
    required Directory cacheDir,
    required Uri baseUri,
    required PersonaProfile persona,
  }) async {
    if (persona.voiceSampleUrl.isEmpty) {
      return null;
    }
    final Uri? voiceUri = _backendUri(persona.voiceSampleUrl, baseUri);
    if (voiceUri == null) {
      return null;
    }
    final String token = _safeCacheToken(
      '${persona.id}_${persona.voiceCacheKey}_voice_sample',
    );

    for (final String extension in const <String>['.wav', '.wave']) {
      final File existing = File('${cacheDir.path}/$token$extension');
      if (await existing.exists() && await existing.length() > 0) {
        return existing.path;
      }
    }

    try {
      final HttpClientRequest request = await client.getUrl(voiceUri);
      final HttpClientResponse response = await request.close();
      if (response.statusCode != HttpStatus.ok) {
        return null;
      }
      final String extension = _voiceSampleExtension(response, voiceUri);
      final Uint8List bytes = Uint8List.fromList(
        await response.expand((List<int> chunk) => chunk).toList(),
      );
      if (bytes.isEmpty) {
        return null;
      }
      final File file = File('${cacheDir.path}/$token$extension');
      await file.writeAsBytes(bytes, flush: true);
      if (extension != '.wav' && extension != '.wave') {
        _log(
          'Cached ${persona.id} voice sample as $extension, but PocketTTS '
          'requires WAV reference audio; using bundled fallback voice.',
        );
        return null;
      }
      _log('Cached ${persona.id} voice sample key=${persona.voiceCacheKey}');
      return file.path;
    } catch (error) {
      _log('Persona voice sample fetch failed for ${persona.id}: $error');
      return null;
    }
  }

  String _voiceSampleExtension(HttpClientResponse response, Uri voiceUri) {
    final String mime =
        response.headers.contentType?.mimeType.toLowerCase() ?? '';
    if (mime == 'audio/wav' || mime == 'audio/wave' || mime == 'audio/x-wav') {
      return '.wav';
    }
    if (mime == 'audio/mpeg' || mime == 'audio/mp3') {
      return '.mp3';
    }
    if (mime == 'audio/flac' || mime == 'audio/x-flac') {
      return '.flac';
    }
    if (mime == 'audio/ogg') {
      return '.ogg';
    }
    final String path = voiceUri.path.toLowerCase();
    for (final String extension in const <String>[
      '.wav',
      '.wave',
      '.mp3',
      '.flac',
      '.ogg',
      '.webm',
    ]) {
      if (path.endsWith(extension)) {
        return extension == '.wave' ? '.wav' : extension;
      }
    }
    return '.wav';
  }

  PersonaProfile? _activeVoicePersona() {
    final PersonaProfile? selected = _selectedPersona;
    if (selected != null) {
      return selected;
    }
    final String? callPersona = _callPersonaName;
    if (callPersona == null) {
      return null;
    }
    return _firstWhereOrNull(
      _personas,
      (PersonaProfile persona) => persona.name == callPersona,
    );
  }

  TalkWizardSummary? _wizardForPersona(PersonaProfile persona) {
    return _firstWhereOrNull(
          _wizards,
          (TalkWizardSummary wizard) => wizard.personaId == persona.name,
        ) ??
        _firstWhereOrNull(
          _wizards,
          (TalkWizardSummary wizard) => wizard.wizardId == persona.name,
        );
  }

  String? _cachedVoiceSamplePath(PersonaProfile? persona) {
    final String? path = persona?.cachedVoiceSamplePath;
    if (path == null || path.trim().isEmpty) {
      return null;
    }
    final File file = File(path);
    if (!file.existsSync()) {
      return null;
    }
    return path;
  }

  String _safeCacheToken(String raw) {
    return raw.replaceAll(RegExp(r'[^a-zA-Z0-9._-]'), '_');
  }

  void _selectVisualPersona(PersonaVisual visual) {
    if (_waitingForGeneratedWelcome || _phase == CallPhase.connecting) {
      return;
    }
    final PersonaProfile? persona = _firstWhereOrNull(
      _personas,
      (PersonaProfile item) => item.name == visual.id,
    );
    if (persona == null) {
      _log('Persona ${visual.id} is not available on the server');
      return;
    }
    setState(() {
      _selectedPersona = persona;
      _welcomeSent = false;
    });
    final TalkWizardSummary? wizard = _wizardForPersona(persona);
    if (wizard != null) {
      unawaited(_startSelectedWizardSession(persona, wizard));
    } else if (_isConnected) {
      _callPersonaName = persona.name;
      _sendJson(<String, Object?>{
        'type': 'set_persona',
        'persona_id': persona.name,
      });
    } else {
      unawaited(_startSelectedPersonaCall());
    }
  }

  Future<void> _startSelectedPersonaCall() async {
    final String personaName =
        _selectedPersona?.name ??
        (_personas.isNotEmpty ? _personas.first.name : 'spark');
    final PersonaProfile? persona = _firstWhereOrNull(
      _personas,
      (PersonaProfile item) => item.name == personaName,
    );
    if (_selectedPersona == null && persona != null) {
      setState(() {
        _selectedPersona = persona;
      });
    }
    if (mounted) {
      setState(() {
        _pendingCallPersonaName = personaName;
        _callPersonaName = personaName;
        _waitingForGeneratedWelcome = true;
        _status = 'Dialing ${_selectedVisual.fullName}';
      });
    }
    await _connect(personaName: personaName);
  }

  Future<void> _startSelectedWizardSession(
    PersonaProfile persona,
    TalkWizardSummary wizard,
  ) async {
    if (_wizardBusy || _wizardGeneratingStory) {
      return;
    }
    if (!widget.enableLocalVoice || !(Platform.isIOS || Platform.isAndroid)) {
      _setStatus('Talk requires local voice setup');
      return;
    }
    final Uri? baseUri = _baseUri();
    if (baseUri == null) {
      _setStatus('Invalid server URL');
      return;
    }
    final int generation = _llmRequestGeneration + 1;
    _llmRequestGeneration = generation;
    await _disconnectSocketOnly();
    final SharedPreferences preferences = await SharedPreferences.getInstance();
    final String introSeenKey = 'storyvault_talk_intro_seen_${wizard.wizardId}';
    final bool introSeen = preferences.getBool(introSeenKey) ?? false;
    if (!mounted || generation != _llmRequestGeneration) {
      return;
    }
    setState(() {
      _selectedPersona = persona;
      _callPersonaName = persona.name;
      _pendingCallPersonaName = persona.name;
      _wizardBusy = true;
      _wizardGeneratingStory = false;
      _wizardQuestionsStarted = false;
      _wizardIntroFinished = false;
      _wizardSessionId = null;
      _wizardIntro = null;
      _wizardState = null;
      _wizardStoryText = '';
      _activeWizardId = wizard.wizardId;
      _assistantText = '';
      _assistantDraft = '';
      _lastUserText = '';
      _wizardStatus = 'Calling ${persona.displayName}';
      _phase = CallPhase.connecting;
      _status = 'Calling';
      _events.clear();
      _metrics.clear();
      _metrics['talk_mode'] = 'guided_story_wizard';
      _metrics['wizard_id'] = wizard.wizardId;
    });
    try {
      final String? referenceAudioPath = _cachedVoiceSamplePath(persona);
      final Future<void> voicePrepareFuture = _localPocketTts.prepare(
        referenceAudioPath: referenceAudioPath,
      );
      final Map<String, dynamic> response =
          await _postJson('/api/talk/wizard-sessions', <String, Object?>{
            'wizard_id': wizard.wizardId,
            'child_profile_id': 'local_child',
            'age_band': '5-8',
            'intro_seen': introSeen,
          }, timeout: const Duration(seconds: 20));
      if (!mounted || generation != _llmRequestGeneration) {
        return;
      }
      setState(() {
        _wizardStatus = 'Warming ${persona.displayName}';
        _status = 'Warming voice';
        _metrics['local_tts_voice_sample_cached'] = referenceAudioPath != null;
      });
      await voicePrepareFuture;
      if (!mounted || generation != _llmRequestGeneration) {
        return;
      }
      final TalkWizardIntro intro = TalkWizardIntro.fromJson(
        (response['intro'] as Map?)?.cast<String, dynamic>(),
      );
      final TalkWizardState state = TalkWizardState.fromJson(
        ((response['state'] as Map?) ?? const <String, dynamic>{})
            .cast<String, dynamic>(),
      );
      setState(() {
        _wizardSessionId = (response['session_id'] as String?) ?? '';
        _wizardIntro = intro;
        _wizardState = state;
        _wizardBusy = false;
        _phase = CallPhase.speaking;
        _status = 'Welcome';
        _wizardStatus = intro.skipAllowed
            ? 'Tap ${intro.skipLabel} to skip the welcome'
            : 'Listen to the welcome';
      });
      final String welcome = intro.prompt.trim();
      if (welcome.isEmpty) {
        _finishWizardIntro();
        return;
      }
      await _speakWizardText(
        welcome,
        generation,
        punctuationPauses: true,
        afterDone: () {
          _finishWizardIntro();
        },
      );
    } catch (error, stackTrace) {
      developer.log(
        'Wizard start failed',
        name: 'StoryVaultTalk',
        error: error,
        stackTrace: stackTrace,
      );
      if (!mounted || generation != _llmRequestGeneration) {
        return;
      }
      setState(() {
        _wizardBusy = false;
        _activeWizardId = '';
        _phase = CallPhase.disconnected;
        _status = 'Wizard unavailable';
        _wizardStatus = 'Could not start story wizard';
        _metrics['wizard_error'] = error.toString();
      });
    }
  }

  Future<void> _disconnectSocketOnly() async {
    _autoListenEnabled = false;
    await _stopListening(sendAudioEnd: false);
    await _socketSubscription?.cancel();
    _socketSubscription = null;
    final WebSocket? socket = _socket;
    _socket = null;
    await socket?.close(WebSocketStatus.normalClosure, 'wizard_mode');
  }

  Future<Map<String, dynamic>> _postJson(
    String path,
    Map<String, Object?> payload, {
    Duration timeout = const Duration(seconds: 30),
  }) async {
    final Uri? uri = _backendUri(path);
    if (uri == null) {
      throw StateError('Invalid server URL');
    }
    final HttpClient client = HttpClient()..connectionTimeout = timeout;
    try {
      final HttpClientRequest request = await client.postUrl(uri);
      request.headers.contentType = ContentType.json;
      request.write(jsonEncode(payload));
      final HttpClientResponse response = await request.close().timeout(
        timeout,
      );
      final String body = await response.transform(utf8.decoder).join();
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw HttpException('HTTP ${response.statusCode}: $body');
      }
      return jsonDecode(body) as Map<String, dynamic>;
    } finally {
      client.close(force: true);
    }
  }

  Future<void> _speakWizardText(
    String text,
    int generation, {
    VoidCallback? afterDone,
    bool punctuationPauses = false,
  }) async {
    if (!mounted || generation != _llmRequestGeneration) {
      return;
    }
    _autoListenEnabled = false;
    _assistantPlaybackGeneration += 1;
    setState(() {
      _assistantText = text;
      _assistantDraft = '';
      _phase = CallPhase.speaking;
      _status = 'Speaking on device';
    });
    if (punctuationPauses) {
      await _playWizardPunctuatedText(
        text,
        generation,
        reason: 'wizard_welcome_punctuation',
        metricsPrefix: 'wizard_welcome',
      );
    } else {
      await _speakAssistantLocally(text);
    }
    if (!mounted || generation != _llmRequestGeneration) {
      return;
    }
    afterDone?.call();
  }

  void _finishWizardIntro() {
    if (!mounted || _wizardSessionId == null) {
      return;
    }
    setState(() {
      _wizardIntroFinished = true;
      _phase = CallPhase.ready;
      _status = 'Ready';
      _wizardStatus = 'Tap I am ready to begin';
    });
  }

  Future<void> _beginWizardQuestions() async {
    final String? sessionId = _wizardSessionId;
    final TalkWizardState? state = _wizardState;
    if (sessionId == null || sessionId.isEmpty || state == null) {
      return;
    }
    final SharedPreferences preferences = await SharedPreferences.getInstance();
    final String? key = _wizardIntro?.seenStorageKey.trim();
    if (key != null && key.isNotEmpty) {
      await preferences.setBool(key, true);
    }
    final TalkWizardSummary? wizard = _selectedPersona == null
        ? null
        : _wizardForPersona(_selectedPersona!);
    if (wizard != null) {
      await preferences.setBool(
        'storyvault_talk_intro_seen_${wizard.wizardId}',
        true,
      );
    }
    final int generation = _llmRequestGeneration;
    setState(() {
      _wizardQuestionsStarted = true;
      _wizardStatus = 'Choose an answer';
      _phase = CallPhase.speaking;
      _status = 'Question';
    });
    await _speakWizardText(
      state.spokenPrompt.isNotEmpty ? state.spokenPrompt : state.prompt,
      generation,
    );
    if (!mounted || generation != _llmRequestGeneration) {
      return;
    }
    setState(() {
      _phase = CallPhase.ready;
      _status = 'Choose';
      _wizardStatus = 'Choose an answer';
    });
  }

  Future<void> _skipWizardIntro() async {
    if (_wizardSessionId == null) {
      return;
    }
    _llmRequestGeneration += 1;
    _cancelLocalStreamingTts();
    await _localPocketTts.stop(resetWorker: false);
    await _audio.stopPlayback();
    _finishWizardIntro();
  }

  Future<void> _answerWizardChoice(TalkWizardChoice choice) async {
    final String? sessionId = _wizardSessionId;
    final TalkWizardState? state = _wizardState;
    if (sessionId == null ||
        sessionId.isEmpty ||
        state == null ||
        _wizardBusy ||
        _wizardGeneratingStory) {
      return;
    }
    final int generation = _llmRequestGeneration + 1;
    _llmRequestGeneration = generation;
    _cancelLocalStreamingTts();
    await _localPocketTts.stop(resetWorker: false);
    await _audio.stopPlayback();
    if (!mounted) {
      return;
    }
    setState(() {
      _wizardBusy = true;
      _lastUserText = choice.label;
      _wizardStatus = 'Saving ${choice.label}';
      _phase = CallPhase.thinking;
      _status = 'Thinking';
    });
    try {
      final Map<String, dynamic> response = await _postJson(
        '/api/talk/wizard-sessions/$sessionId/advance',
        <String, Object?>{
          'state_id': state.stateId,
          'choice_id': choice.choiceId,
          'idempotency_key': 'flutter-${DateTime.now().microsecondsSinceEpoch}',
        },
        timeout: const Duration(seconds: 20),
      );
      if (!mounted || generation != _llmRequestGeneration) {
        return;
      }
      final String status = (response['status'] as String?) ?? '';
      if (status == 'ready_to_generate') {
        setState(() {
          _wizardBusy = false;
          _wizardState = null;
          _wizardGeneratingStory = true;
          _wizardStatus = 'Building your story';
          _phase = CallPhase.thinking;
          _status = 'Creating story';
        });
        await _generateWizardStory(generation);
        return;
      }
      final TalkWizardState nextState = TalkWizardState.fromJson(
        ((response['state'] as Map?) ?? const <String, dynamic>{})
            .cast<String, dynamic>(),
      );
      setState(() {
        _wizardBusy = false;
        _wizardState = nextState;
        _wizardStatus = 'Choose an answer';
        _phase = CallPhase.speaking;
        _status = 'Question';
      });
      await _speakWizardText(
        nextState.spokenPrompt.isNotEmpty
            ? nextState.spokenPrompt
            : nextState.prompt,
        generation,
      );
      if (!mounted || generation != _llmRequestGeneration) {
        return;
      }
      setState(() {
        _phase = CallPhase.ready;
        _status = 'Choose';
        _wizardStatus = 'Choose an answer';
      });
    } catch (error, stackTrace) {
      developer.log(
        'Wizard advance failed',
        name: 'StoryVaultTalk',
        error: error,
        stackTrace: stackTrace,
      );
      if (!mounted || generation != _llmRequestGeneration) {
        return;
      }
      setState(() {
        _wizardBusy = false;
        _phase = CallPhase.ready;
        _status = 'Try again';
        _wizardStatus = 'Could not save that answer. Try another tap.';
        _metrics['wizard_advance_error'] = error.toString();
      });
    }
  }

  Future<void> _generateWizardStory(int generation) async {
    final String? sessionId = _wizardSessionId;
    if (sessionId == null || sessionId.isEmpty) {
      return;
    }
    try {
      final Map<String, dynamic> response = await _postJson(
        '/api/talk/wizard-sessions/$sessionId/generate-story',
        <String, Object?>{
          'idempotency_key':
              'flutter-story-${DateTime.now().microsecondsSinceEpoch}',
        },
        timeout: const Duration(minutes: 4),
      );
      if (!mounted || generation != _llmRequestGeneration) {
        return;
      }
      final String story = ((response['story'] as String?) ?? '').trim();
      if (story.isEmpty) {
        throw StateError('Story server returned empty text.');
      }
      setState(() {
        _wizardGeneratingStory = false;
        _wizardStoryText = story;
        _assistantText = story;
        _wizardStatus = 'Story ready';
        _phase = CallPhase.speaking;
        _status = 'Playing story';
        _metrics['wizard_story_chars'] = story.length;
        _metrics['wizard_story_words'] = story.split(RegExp(r'\s+')).length;
      });
      await _playWizardStory(story, generation);
    } catch (error, stackTrace) {
      developer.log(
        'Wizard story generation failed',
        name: 'StoryVaultTalk',
        error: error,
        stackTrace: stackTrace,
      );
      if (!mounted || generation != _llmRequestGeneration) {
        return;
      }
      setState(() {
        _wizardGeneratingStory = false;
        _wizardBusy = false;
        _phase = CallPhase.ready;
        _status = 'Story failed';
        _wizardStatus = 'The story did not arrive. Try again later.';
        _metrics['wizard_generate_error'] = error.toString();
      });
    }
  }

  Future<void> _playWizardStory(String story, int generation) async {
    if (!mounted || generation != _llmRequestGeneration) {
      return;
    }
    final TalkVoiceChunkBoundary chunkBoundary =
        await _currentTalkVoiceChunkBoundary();
    if (!mounted || generation != _llmRequestGeneration) {
      return;
    }
    _autoListenEnabled = false;
    _beginLocalStreamingTts(generation);
    _enqueueWizardStoryChunks(story, generation, chunkBoundary: chunkBoundary);
    await _finishLocalStreamingTts(generation);
    if (!mounted || generation != _llmRequestGeneration) {
      return;
    }
    setState(() {
      _phase = CallPhase.ready;
      _status = 'Story finished';
      _wizardStatus = 'Story finished';
    });
  }

  Future<void> _playWizardPunctuatedText(
    String text,
    int generation, {
    required String reason,
    required String metricsPrefix,
  }) async {
    if (!mounted || generation != _llmRequestGeneration) {
      return;
    }
    final TalkVoiceChunkBoundary chunkBoundary =
        await _currentTalkVoiceChunkBoundary();
    if (!mounted || generation != _llmRequestGeneration) {
      return;
    }
    _beginLocalStreamingTts(generation);
    _enqueueWizardPunctuatedText(
      text,
      generation,
      reason: reason,
      metricsPrefix: metricsPrefix,
      chunkBoundary: chunkBoundary,
    );
    await _finishLocalStreamingTts(generation);
  }

  void _enqueueWizardStoryChunks(
    String story,
    int generation, {
    required TalkVoiceChunkBoundary chunkBoundary,
  }) {
    _enqueueWizardPunctuatedText(
      story,
      generation,
      reason: 'wizard_story_punctuation',
      metricsPrefix: 'wizard_story',
      chunkBoundary: chunkBoundary,
    );
  }

  void _enqueueWizardPunctuatedText(
    String text,
    int generation, {
    required String reason,
    required String metricsPrefix,
    required TalkVoiceChunkBoundary chunkBoundary,
  }) {
    final List<_WizardStoryTtsUnit> units = _splitWizardStoryForTts(
      text,
      chunkBoundary: chunkBoundary,
    );
    for (var index = 0; index < units.length; index += 1) {
      final bool last = index == units.length - 1;
      final _WizardStoryTtsUnit unit = units[index];
      _enqueueLocalTtsChunk(
        unit.text,
        generation,
        reason: reason,
        pauseAfterMs: last ? 0 : unit.pauseAfterMs,
      );
    }
    if (mounted) {
      setState(() {
        _metrics['${metricsPrefix}_tts_chunks'] = units.length;
        _metrics['${metricsPrefix}_tts_mode'] =
            talkVoiceChunkBoundaryStorageValue(chunkBoundary);
      });
    }
  }

  List<_WizardStoryTtsUnit> _splitWizardStoryForTts(
    String story, {
    required TalkVoiceChunkBoundary chunkBoundary,
  }) {
    final List<String> paragraphs = story
        .split(RegExp(r'\n\s*\n+'))
        .map((String value) => value.replaceAll(RegExp(r'\s+'), ' ').trim())
        .where((String value) => value.isNotEmpty)
        .toList(growable: false);
    final List<String> source = paragraphs.isEmpty
        ? <String>[story.replaceAll(RegExp(r'\s+'), ' ').trim()]
        : paragraphs;
    final List<_WizardStoryTtsUnit> units = <_WizardStoryTtsUnit>[];
    for (final String paragraph in source) {
      final List<_WizardStoryTtsUnit> paragraphUnits =
          _splitWizardParagraphForTts(paragraph, chunkBoundary: chunkBoundary);
      for (var index = 0; index < paragraphUnits.length; index += 1) {
        final _WizardStoryTtsUnit unit = paragraphUnits[index];
        units.add(
          index == paragraphUnits.length - 1
              ? _WizardStoryTtsUnit(
                  text: unit.text,
                  pauseAfterMs: math.max(
                    unit.pauseAfterMs,
                    _wizardStoryParagraphPauseMs,
                  ),
                )
              : unit,
        );
      }
    }
    return units;
  }

  List<_WizardStoryTtsUnit> _splitWizardParagraphForTts(
    String paragraph, {
    required TalkVoiceChunkBoundary chunkBoundary,
  }) {
    final String normalized = paragraph.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (normalized.isEmpty) {
      return const <_WizardStoryTtsUnit>[];
    }
    final List<_WizardStoryTtsUnit> units = <_WizardStoryTtsUnit>[];
    var start = 0;
    while (start < normalized.length) {
      final int? punctuationEnd = _nextWizardStoryBoundaryEnd(
        normalized,
        start,
        chunkBoundary: chunkBoundary,
      );
      final int end =
          punctuationEnd ??
          math.min(normalized.length, start + _wizardStoryPhraseHardMaxChars);
      final String phrase = normalized.substring(start, end).trim();
      if (phrase.isNotEmpty) {
        final int punctuationCode = punctuationEnd == null
            ? 0
            : _lastWizardStoryPunctuationCode(phrase);
        units.addAll(
          _splitLongWizardPhrase(
            phrase,
            pauseAfterMs: _pauseAfterWizardStoryPunctuation(punctuationCode),
          ),
        );
      }
      start = end;
      while (start < normalized.length &&
          normalized.codeUnitAt(start) <= 0x20) {
        start += 1;
      }
    }
    return units;
  }

  int? _nextWizardStoryBoundaryEnd(
    String text,
    int start, {
    required TalkVoiceChunkBoundary chunkBoundary,
  }) {
    if (chunkBoundary == TalkVoiceChunkBoundary.paragraph) {
      return null;
    }
    for (var index = start; index < text.length; index += 1) {
      final int code = text.codeUnitAt(index);
      if (!_isWizardStoryBoundaryPunctuation(code, chunkBoundary)) {
        continue;
      }
      var end = index + 1;
      while (end < text.length) {
        final int next = text.codeUnitAt(end);
        if (next == 0x22 || next == 0x27 || next == 0x29 || next == 0x5d) {
          end += 1;
          continue;
        }
        break;
      }
      return end;
    }
    return null;
  }

  bool _isWizardStoryBoundaryPunctuation(
    int code,
    TalkVoiceChunkBoundary chunkBoundary,
  ) {
    return switch (chunkBoundary) {
      TalkVoiceChunkBoundary.punctuation => _isWizardStoryPausePunctuation(
        code,
      ),
      TalkVoiceChunkBoundary.fullStop => _isWizardStorySentencePunctuation(
        code,
      ),
      TalkVoiceChunkBoundary.paragraph => false,
    };
  }

  List<_WizardStoryTtsUnit> _splitLongWizardPhrase(
    String phrase, {
    required int pauseAfterMs,
  }) {
    if (phrase.length <= _wizardStoryPhraseHardMaxChars) {
      return <_WizardStoryTtsUnit>[
        _WizardStoryTtsUnit(text: phrase, pauseAfterMs: pauseAfterMs),
      ];
    }
    final List<_WizardStoryTtsUnit> units = <_WizardStoryTtsUnit>[];
    String remaining = phrase;
    while (remaining.length > _wizardStoryPhraseHardMaxChars) {
      final int split = _wordBoundaryForText(
        remaining,
        _wizardStoryPhraseTargetChars,
      );
      units.add(
        _WizardStoryTtsUnit(
          text: remaining.substring(0, split).trim(),
          pauseAfterMs: _wizardStoryForcedSplitPauseMs,
        ),
      );
      remaining = remaining.substring(split).trimLeft();
    }
    if (remaining.trim().isNotEmpty) {
      units.add(
        _WizardStoryTtsUnit(text: remaining.trim(), pauseAfterMs: pauseAfterMs),
      );
    }
    return units;
  }

  int _wordBoundaryForText(String text, int maxChars) {
    final int end = math.min(text.length, math.max(1, maxChars));
    final int minimum = math.max(1, (end * 0.55).round());
    for (var index = end; index > minimum; index -= 1) {
      if (text.codeUnitAt(index - 1) <= 0x20) {
        return index;
      }
    }
    return end;
  }

  bool _isWizardStoryPausePunctuation(int code) {
    return code == 0x2c ||
        code == 0x3b ||
        code == 0x3a ||
        code == 0x2e ||
        code == 0x21 ||
        code == 0x3f;
  }

  bool _isWizardStorySentencePunctuation(int code) {
    return code == 0x2e || code == 0x21 || code == 0x3f;
  }

  int _lastWizardStoryPunctuationCode(String text) {
    for (var index = text.length - 1; index >= 0; index -= 1) {
      final int code = text.codeUnitAt(index);
      if (_isWizardStoryPausePunctuation(code)) {
        return code;
      }
    }
    return 0;
  }

  int _pauseAfterWizardStoryPunctuation(int code) {
    if (code == 0x2c || code == 0x3b || code == 0x3a) {
      return _wizardStoryCommaPauseMs;
    }
    if (code == 0x2e || code == 0x21 || code == 0x3f) {
      return _wizardStorySentencePauseMs;
    }
    return _wizardStoryForcedSplitPauseMs;
  }

  Future<void> _endWizardSession() async {
    _llmRequestGeneration += 1;
    _cancelLocalStreamingTts();
    _cancelAssistantPlaybackTimer();
    await _localPocketTts.stop(resetWorker: false);
    await _audio.stopPlayback();
    if (!mounted) {
      return;
    }
    setState(() {
      _wizardSessionId = null;
      _wizardIntro = null;
      _wizardState = null;
      _wizardIntroFinished = false;
      _wizardBusy = false;
      _wizardGeneratingStory = false;
      _wizardQuestionsStarted = false;
      _wizardStoryText = '';
      _activeWizardId = '';
      _wizardStatus = '';
      _assistantText = '';
      _assistantDraft = '';
      _lastUserText = '';
      _phase = CallPhase.disconnected;
      _status = 'Disconnected';
      _callPersonaName = null;
      _pendingCallPersonaName = null;
      _liveAudioCaption = '';
    });
  }

  Future<void> _connect({String? personaName}) async {
    if (_phase == CallPhase.connecting || _isConnected) {
      return;
    }
    if (!widget.enableLocalVoice || !(Platform.isIOS || Platform.isAndroid)) {
      _setStatus('Talk requires local voice setup');
      return;
    }
    if (!mounted) {
      return;
    }
    final String requestedPersonaName =
        personaName ??
        _pendingCallPersonaName ??
        _selectedPersona?.name ??
        'spark';
    _callPersonaName = requestedPersonaName;

    final Uri? wsUri = _webSocketUri();
    if (wsUri == null) {
      _setStatus('Invalid server URL');
      if (mounted) {
        setState(() {
          _waitingForGeneratedWelcome = false;
          _pendingCallPersonaName = null;
          _callPersonaName = null;
        });
      }
      return;
    }

    await _loadPersonas(preferredPersonaName: requestedPersonaName);
    final bool permitted = await _audio.requestMicrophonePermission();
    if (!permitted) {
      _setStatus('Microphone permission denied');
      if (mounted) {
        setState(() {
          _waitingForGeneratedWelcome = false;
          _pendingCallPersonaName = null;
          _callPersonaName = null;
        });
      }
      return;
    }

    setState(() {
      _phase = CallPhase.connecting;
      _status = 'Connecting';
      _welcomeSent = false;
      _eventCount = 0;
      _micBytes = 0;
      _audioBytes = 0;
      _events.clear();
      _metrics.clear();
      _assistantText = '';
      _assistantDraft = '';
      _lastUserText = '';
      _liveAudioCaption = '';
      _callPersonaName = requestedPersonaName;
      _ttsMode = _preferredTtsMode;
      _sessionStartAcknowledged = false;
      _metrics['tts_mode_preference'] = _preferredTtsMode;
    });
    final String ttsModePreference = _preferredTtsMode;

    try {
      final WebSocket socket = await WebSocket.connect(wsUri.toString());
      _socket = socket;
      _autoListenEnabled = true;
      _socketSubscription = socket.listen(
        _handleSocketMessage,
        onDone: _handleSocketDone,
        onError: _handleSocketError,
      );
      _sendJson(<String, Object?>{
        'type': 'start',
        'persona_id': requestedPersonaName,
        'tts_mode_preference': ttsModePreference,
        'client_tts': <String, Object?>{
          'available': true,
          'engine': 'pocket_tts',
          'voice_cloning': 'reference_audio',
        },
      });
      _log('WebSocket connected as $requestedPersonaName');
    } catch (error) {
      _log('Connect failed: $error');
      if (!mounted) {
        return;
      }
      setState(() {
        _socket = null;
        _phase = CallPhase.disconnected;
        _status = 'Connection failed';
        _waitingForGeneratedWelcome = false;
        _pendingCallPersonaName = null;
        _callPersonaName = null;
      });
    }
  }

  Future<void> _disconnect() async {
    _disconnecting = true;
    _llmRequestGeneration += 1;
    _cancelLocalStreamingTts();
    _cancelListeningTimeout();
    _cancelConnectedIdleTimer();
    _cancelAssistantPlaybackTimer();
    _autoListenEnabled = false;
    await _stopListening(sendAudioEnd: false);
    await _localPocketTts.stop(resetWorker: true);
    await _audio.stopPlayback();
    await _socketSubscription?.cancel();
    _socketSubscription = null;
    final WebSocket? socket = _socket;
    _socket = null;
    await socket?.close(WebSocketStatus.normalClosure, 'client_disconnect');
    if (!mounted) {
      return;
    }
    setState(() {
      _phase = CallPhase.disconnected;
      _status = 'Disconnected';
      _turnRunning = false;
      _welcomeSent = false;
      _waitingForGeneratedWelcome = false;
      _pendingCallPersonaName = null;
      _callPersonaName = null;
      _autoListenEnabled = false;
      _sessionStartAcknowledged = false;
      _liveAudioCaption = '';
    });
    _disconnecting = false;
  }

  void _handleSocketMessage(dynamic message) {
    if (message is String) {
      final Object? decoded = jsonDecode(message);
      if (decoded is Map<String, dynamic>) {
        unawaited(_handleJsonEvent(decoded));
      }
      return;
    }

    if (message is List<int>) {
      _log('Unexpected server audio frame; local TTS is required');
      unawaited(_closeUnsupportedTtsMode('server_audio_frame'));
    }
  }

  Future<void> _handleJsonEvent(Map<String, dynamic> event) async {
    final String type = (event['type'] as String?) ?? 'event';
    _eventCount += 1;

    switch (type) {
      case 'session_ready':
        _readAudioConfig(event);
        _rememberTtsMode(event);
        await _audio.startPlayback(sampleRate: _outputSampleRate);
        if (!mounted) {
          return;
        }
        final bool configuredReady = _isConfiguredSessionReady(event);
        if (!configuredReady) {
          setState(() {
            _replacePersonasFromSession(event);
            _metrics['session_ready_ignored'] = 'pre_start';
          });
          return;
        }
        setState(() {
          _sessionStartAcknowledged = true;
          _metrics['session_ready_ignored'] = 'none';
          _phase = CallPhase.ready;
          _status = 'Ready';
          _replacePersonasFromSession(event);
        });
        _sendWelcomeIfReady(event);
      case 'persona_selected':
        final String? persona =
            (event['persona_id'] as String?) ?? (event['persona'] as String?);
        if (persona != null && mounted) {
          final String? lockedPersona = _callPersonaName;
          if (lockedPersona != null && persona != lockedPersona) {
            _log(
              'Ignored persona_selected $persona during locked '
              '$lockedPersona call',
            );
            return;
          }
          setState(() {
            _selectedPersona =
                _firstWhereOrNull(
                  _personas,
                  (PersonaProfile item) => item.name == persona,
                ) ??
                _selectedPersona;
          });
        }
      case 'turn_started':
        if (!mounted) {
          return;
        }
        _resetAssistantPlaybackTracking();
        if (_usesLocalPocketTts) {
          _llmRequestGeneration += 1;
          _beginLocalStreamingTts(_llmRequestGeneration);
        }
        setState(() {
          _turnRunning = true;
          _phase = CallPhase.thinking;
          _status = 'Thinking';
          _lastUserText = (event['user_text'] as String?) ?? _lastUserText;
          _assistantDraft = '';
          _assistantText = '';
        });
      case 'asr_started':
        _rememberAsrAudio(event);
        _setPhase(CallPhase.thinking, 'Transcribing');
      case 'asr_audio_started':
        _cancelConnectedIdleTimer();
        if (_voiceStarted) {
          _schedulePostVoiceSilenceTimeout();
        }
        _setPhase(CallPhase.listening, 'Listening');
      case 'asr_audio_buffered':
        _rememberAsrAudio(event);
      case 'asr_status':
        _log((event['message'] as String?) ?? 'ASR status');
      case 'transcript_partial':
        _setLastUserText((event['text'] as String?) ?? '');
      case 'transcript_final':
        _setLastUserText((event['text'] as String?) ?? '');
        _setPhase(CallPhase.thinking, 'Thinking');
      case 'assistant_delta':
        final String delta = (event['text'] as String?) ?? '';
        if (!mounted) {
          return;
        }
        setState(() {
          _assistantDraft += delta;
        });
        _scrollTranscriptSoon();
      case 'tts_phrase_started':
        if (mounted) {
          setState(() {
            _waitingForGeneratedWelcome = false;
            _pendingCallPersonaName = null;
          });
        }
        if (_phase != CallPhase.listening) {
          _setPhase(CallPhase.speaking, 'Speaking');
        }
      case 'tts_text_chunk':
        final String text = (event['text'] as String?) ?? '';
        if (text.isNotEmpty && mounted) {
          if (_usesLocalPocketTts) {
            if (_localTtsStreamGeneration == 0) {
              _llmRequestGeneration += 1;
              _beginLocalStreamingTts(_llmRequestGeneration);
            }
            _enqueueLocalTtsChunk(
              text,
              _localTtsStreamGeneration,
              reason: 'server_text_chunk',
            );
          } else {
            setState(() {
              _assistantDraft += text;
            });
            _scrollTranscriptSoon();
          }
        }
      case 'tts_mode_changed':
        _rememberTtsMode(event);
      case 'tts_stop_requested':
      case 'tts_phrase_stopped':
      case 'tts_phrase_dropped':
        _log('$type ${event['reason'] ?? ''}'.trim());
      case 'metric':
        final String? name = event['name'] as String?;
        if (name != null && mounted) {
          setState(() {
            _metrics[name] = event['value'];
          });
        }
      case 'token_usage':
        _rememberTokenUsage(event);
      case 'turn_finished':
        final Map<String, dynamic>? metrics = (event['metrics'] as Map?)
            ?.cast<String, dynamic>();
        if (!mounted) {
          return;
        }
        final String textToSpeak =
            ((event['assistant_text'] as String?) ?? _assistantDraft).trim();
        final bool shouldUseLocalPocketTts =
            _usesLocalPocketTts && textToSpeak.isNotEmpty;
        _logTtsText(
          'Server turn_finished local_tts=$shouldUseLocalPocketTts',
          textToSpeak,
        );
        setState(() {
          _waitingForGeneratedWelcome = false;
          _turnRunning = false;
          if (_phase != CallPhase.listening) {
            _phase = shouldUseLocalPocketTts
                ? CallPhase.speaking
                : CallPhase.ready;
            _status = shouldUseLocalPocketTts ? 'Speaking on device' : 'Ready';
          }
          _assistantText = textToSpeak;
          if (metrics != null) {
            _metrics.addAll(metrics);
          }
        });
        if (shouldUseLocalPocketTts) {
          final int generation = _localTtsStreamGeneration;
          if (generation != 0) {
            unawaited(_finishLocalStreamingTts(generation));
          } else {
            unawaited(_speakAssistantLocally(textToSpeak));
          }
        } else if (_phase != CallPhase.listening) {
          _scheduleAssistantPlaybackDone();
        }
        _scrollTranscriptSoon();
      case 'asr_empty':
        _rememberAsrAudio(event);
        final String reason = (event['reason'] as String?) ?? 'empty';
        _log('ASR empty: $reason');
        await _pauseListening(status: 'No speech detected');
      case 'turn_cancelled':
        await _pauseListening(status: 'Ready');
      case 'error':
        if (mounted) {
          setState(() {
            _waitingForGeneratedWelcome = false;
            _pendingCallPersonaName = null;
          });
        }
        _setStatus((event['message'] as String?) ?? 'Server error');
        _log('Error: ${event['message'] ?? 'unknown'}');
      default:
        break;
    }
  }

  Future<void> _startListening({bool assistantAlreadyStopped = false}) async {
    if (!_isConnected || _phase == CallPhase.connecting) {
      return;
    }
    _cancelConnectedIdleTimer();
    _cancelAssistantPlaybackTimer();

    if (!assistantAlreadyStopped &&
        (_turnRunning || _phase == CallPhase.speaking)) {
      await _stopAssistantAudio();
    }
    _sendJson(<String, Object?>{'type': 'clear_audio'});

    final bool permitted = await _audio.requestMicrophonePermission();
    if (!permitted) {
      _setStatus('Microphone permission denied');
      return;
    }

    await _micSubscription?.cancel();
    _listenStartMicBytes = _micBytes;
    _listenStartMicFrames = _micFramesSent;
    _listenStartedAtMs = DateTime.now().millisecondsSinceEpoch;
    _lastMicFrameAtMs = _listenStartedAtMs;
    _lastVoiceAtMs = 0;
    _voiceStartedAtMs = 0;
    _voiceFrameStreak = 0;
    _noiseFloorFrames = 0;
    _voiceStarted = false;
    _listeningStopRequested = false;
    _preSpeechFrames.clear();
    _localSpeechFrames.clear();
    _localFallbackFrames.clear();
    _localFallbackBytes = 0;
    _preSpeechBytes = 0;
    _micLevel = 0;
    _noiseRmsFloor = 0;
    _noisePeakFloor = 0;
    _micSubscription = _audio.micFrames.listen(
      (SparkMicFrame micFrame) {
        final Uint8List frame = micFrame.pcm16;
        _lastMicFrameAtMs = DateTime.now().millisecondsSinceEpoch;
        final _MicFrameStats stats = _analyzeMicFrame(frame);
        _seedNoiseFloor(stats);
        final bool nativeSpeech = micFrame.isSpeech ?? stats.isHumanVoice;
        final bool isHumanVoice = _isHumanVoiceFrame(
          nativeSpeech: nativeSpeech,
          stats: stats,
        );
        _updateNoiseFloor(stats, acceptedVoice: isHumanVoice);
        _micLevel = (_micLevel * 0.62) + (stats.level * 0.38);
        if (micFrame.vadSource.isNotEmpty) {
          _nativeVadSource = micFrame.vadSource;
        }
        if (micFrame.vadMode.isNotEmpty) {
          _nativeVadMode = micFrame.vadMode;
        }

        if (!_voiceStarted) {
          _bufferPreSpeechFrame(frame);
          if (_usesDeviceAsrForTurn) {
            _bufferLocalFallbackFrame(frame);
          }
          if (isHumanVoice) {
            _voiceFrameStreak += 1;
          } else {
            _voiceFrameStreak = 0;
          }
          if (_voiceFrameStreak >= _voiceStartFrames) {
            _voiceStarted = true;
            _lastVoiceAtMs = _lastMicFrameAtMs;
            _voiceStartedAtMs = _lastMicFrameAtMs;
            _flushPreSpeechFrames();
            if (mounted) {
              setState(() {
                _metrics['vad_rms'] = stats.rms.toStringAsFixed(4);
                _metrics['vad_peak'] = stats.peak.toStringAsFixed(4);
                _metrics['vad_zcr'] = stats.zeroCrossingRate.toStringAsFixed(4);
                _metrics['noise_rms_floor'] = _noiseRmsFloor.toStringAsFixed(4);
                _metrics['voice_rms_gate'] = _adaptiveVoiceRmsThreshold
                    .toStringAsFixed(4);
                _metrics['vad_source'] = _nativeVadSource;
                if (_nativeVadMode.isNotEmpty) {
                  _metrics['vad_mode'] = _nativeVadMode;
                }
              });
            }
            _log('Voice detected');
            _schedulePostVoiceSilenceTimeout();
          }
        } else {
          _sendMicFrame(frame);
          if (isHumanVoice) {
            _lastVoiceAtMs = _lastMicFrameAtMs;
            _schedulePostVoiceSilenceTimeout();
          }
          if (!_listeningStopRequested &&
              _lastMicFrameAtMs - _voiceStartedAtMs >=
                  _maxUtteranceDuration.inMilliseconds) {
            _listeningStopRequested = true;
            _log('Max utterance window reached');
            unawaited(_stopListening());
            return;
          }
        }

        _micFrameUiCounter += 1;
        if (_micFrameUiCounter >= 3 && mounted) {
          _micFrameUiCounter = 0;
          setState(() {
            final int sentBytes = _micBytes - _listenStartMicBytes;
            if (_voiceStarted) {
              _status = 'Listening - ${_formatBytes(sentBytes)} sent';
            } else if (_isNoiseCalibrating) {
              _status = 'Listening - sampling room';
            } else {
              _status = 'Listening - waiting for voice';
            }
          });
        }
      },
      onError: (Object error) {
        _log('Mic stream error: $error');
      },
    );
    await Future<void>.delayed(const Duration(milliseconds: 80));

    final bool started = await _audio.startRecording(
      sampleRate: _inputSampleRate,
      frameMs: _frameMs,
    );
    if (!started) {
      await _micSubscription?.cancel();
      _micSubscription = null;
      _setStatus('Microphone unavailable');
      await _refreshRecordingStatus();
      return;
    }

    if (!mounted) {
      return;
    }
    setState(() {
      _phase = CallPhase.listening;
      _status = 'Listening - speak now';
      _lastUserText = '';
      _metrics['fad_start_wait_s'] = _formatSeconds(_firstVoiceWaitSeconds);
      _metrics['fad_end_wait_s'] = _formatSeconds(_endWaitSeconds);
    });
    _log('Mic recording started');
    _startRecordingWatch();
    _cancelConnectedIdleTimer();
    _scheduleFirstVoiceTimeout();
  }

  Future<void> _stopListening({bool sendAudioEnd = true}) async {
    _cancelListeningTimeout();
    _stopRecordingWatch();
    await _refreshRecordingStatus();
    final Map<String, dynamic> stopStatus = await _audio.stopRecording();
    await _micSubscription?.cancel();
    _micSubscription = null;
    if (sendAudioEnd && _usesDeviceAsrForTurn) {
      final int utteranceBytes = _micBytes - _listenStartMicBytes;
      final int utteranceFrames = _micFramesSent - _listenStartMicFrames;
      final List<Uint8List> frames = _localSpeechFrames
          .map(Uint8List.fromList)
          .toList(growable: false);
      _clearLocalCaptureBuffers();
      if (mounted) {
        setState(() {
          _micLevel = 0;
          _metrics['client_mic_bytes'] = utteranceBytes;
          _metrics['client_mic_frames'] = utteranceFrames;
          _metrics['asr_source'] = 'sherpa_whisper_tiny_en_int8';
          _metrics['asr_audio_frames'] = frames.length;
          _metrics['asr_native_recording_frames'] = stopStatus['framesRead'];
          _metrics['asr_native_recording_bytes'] = stopStatus['bytesRead'];
        });
      }
      _setPhase(CallPhase.thinking, 'Transcribing on this device');
      final LocalWhisperAsrResult asrResult = await _localWhisperAsr
          .transcribePcm16Frames(
            frames,
            sampleRate: _inputSampleRate,
            numThreads: 2,
          );
      final String transcript = asrResult.text.trim();
      final String whisperOutput =
          'source=sherpa_whisper_tiny_en_int8\n'
          'elapsed_ms=${asrResult.elapsedMilliseconds}\n'
          'audio_s=${asrResult.audioDurationSeconds.toStringAsFixed(2)}\n'
          'samples=${asrResult.sampleCount}\n'
          'frames=${frames.length}\n'
          'text="$transcript"';
      _writeTalkTextLog('WHISPER_ASR $whisperOutput');
      if (mounted) {
        setState(() {
          _metrics['asr_transcript'] = transcript;
          _metrics['whisper_asr_output'] = whisperOutput;
          _metrics['asr_ms'] = asrResult.elapsedMilliseconds;
          _metrics['asr_audio_s'] = asrResult.audioDurationSeconds
              .toStringAsFixed(2);
          _metrics['asr_samples'] = asrResult.sampleCount;
        });
      }
      if (transcript.isEmpty) {
        _log('Sherpa Whisper returned no transcript');
        if (mounted) {
          setState(() {
            _phase = CallPhase.ready;
            _status = 'No speech detected';
          });
        }
        _scheduleConnectedIdleTimer();
        return;
      }
      await _flushPlaybackAfterAsr();
      _setLastUserText(transcript);
      _setPhase(CallPhase.thinking, 'Heard ${transcript.length} characters');
      if (_socket != null) {
        _sendServerTextTurn(transcript, turnKind: 'voice');
      } else {
        _setPhase(CallPhase.disconnected, 'Connection lost');
        _scheduleConnectedIdleTimer();
      }
      return;
    }
    if (sendAudioEnd && _socket != null) {
      final int utteranceBytes = _micBytes - _listenStartMicBytes;
      final int utteranceFrames = _micFramesSent - _listenStartMicFrames;
      if (utteranceBytes <= 0) {
        _log('No microphone frames reached Flutter');
        _sendJson(<String, Object?>{'type': 'clear_audio'});
        if (mounted) {
          setState(() {
            _phase = CallPhase.ready;
            _status = 'Paused - no voice';
            _micLevel = 0;
            _metrics['client_mic_bytes'] = 0;
            _metrics['client_mic_frames'] = 0;
          });
        }
        _scheduleConnectedIdleTimer();
        return;
      }
      if (mounted) {
        setState(() {
          _micLevel = 0;
          _metrics['client_mic_bytes'] = utteranceBytes;
          _metrics['client_mic_frames'] = utteranceFrames;
        });
      }
      _sendJson(<String, Object?>{'type': 'audio_end'});
      _setPhase(
        CallPhase.thinking,
        'Transcribing ${_formatBytes(utteranceBytes)}',
      );
    } else if (mounted && _phase == CallPhase.listening) {
      setState(() {
        _phase = CallPhase.ready;
        _status = 'Ready';
        _micLevel = 0;
      });
      _scheduleConnectedIdleTimer();
    }
  }

  Future<void> _stopAssistantAudio() async {
    _cancelLocalStreamingTts();
    _cancelAssistantPlaybackTimer();
    _llmRequestGeneration += 1;
    _assistantPlaybackGeneration += 1;
    _assistantPlaybackEndsAtMs = 0;
    await _localPocketTts.stop(resetWorker: true);
    await _audio.stopPlayback();
    _sendJson(<String, Object?>{
      'type': 'stop_audio',
      'reason': 'client_barge_in',
    });
    await _audio.startPlayback(sampleRate: _outputSampleRate);
  }

  Future<void> _playDiagnosticTone() async {
    if (!_diagnosticsEnabled) {
      return;
    }
    if (!mounted) {
      return;
    }
    setState(() {
      _metrics['diagnostic_tone_status'] = 'starting';
      _liveAudioCaption = 'Playing test tone';
    });
    try {
      final Map<String, dynamic> status = await _audio.playDiagnosticTone();
      if (!mounted) {
        return;
      }
      setState(() {
        _metrics['diagnostic_tone_status'] = 'scheduled';
        _metrics['diagnostic_tone_ms'] = status['diagnosticToneMs'];
        _metrics['diagnostic_tone_hz'] = status['diagnosticToneHz'];
        _metrics['diagnostic_tone_bytes'] = status['diagnosticToneBytes'];
        _metrics['diagnostic_tone_playing'] = status['playing'];
        _metrics['diagnostic_tone_scheduled_buffers'] =
            status['scheduledBuffers'];
        _metrics['diagnostic_tone_pending_buffers'] = status['pendingBuffers'];
        _metrics['diagnostic_tone_write_calls'] = status['writeCalls'];
        _metrics['diagnostic_tone_written_bytes'] = status['writtenBytes'];
        _metrics['diagnostic_tone_no_player_drops'] =
            status['droppedNoPlayerWrites'];
        _metrics['diagnostic_tone_error'] = null;
      });
      _log('Diagnostic tone scheduled');
      await Future<void>.delayed(const Duration(milliseconds: 900));
      if (mounted && _liveAudioCaption == 'Playing test tone') {
        _setLiveAudioCaption('');
      }
    } catch (error, stackTrace) {
      developer.log(
        'Diagnostic tone failed',
        name: 'StoryVaultTalk',
        error: error,
        stackTrace: stackTrace,
      );
      if (!mounted) {
        return;
      }
      setState(() {
        _metrics['diagnostic_tone_status'] = 'failed';
        _metrics['diagnostic_tone_error'] = error.toString();
        _liveAudioCaption = '';
      });
      _log('Diagnostic tone failed: $error');
    }
  }

  Future<void> _flushPlaybackAfterAsr() async {
    _cancelLocalStreamingTts();
    await _localPocketTts.stop();
    await _audio.stopPlayback();
    _assistantPlaybackEndsAtMs = 0;
    _setLiveAudioCaption('');
    if (mounted) {
      setState(() {
        _metrics['playback_flush_after_asr'] = true;
      });
    }
    _log('Playback buffer flushed after ASR');
  }

  Future<void> _speakAssistantLocally(String text) async {
    final String rawTrimmed = text.replaceAll(RegExp(r'\s+'), ' ').trim();
    final _SanitizedTtsText sanitized = _sanitizePocketTtsText(rawTrimmed);
    final String trimmed = _normalizeLocalTtsChunkText(sanitized.text);
    if (trimmed.isEmpty || !mounted) {
      return;
    }
    final int generation = _assistantPlaybackGeneration;
    final int speakRequestId = _localTtsSpeakRequestId + 1;
    _localTtsSpeakRequestId = speakRequestId;
    final int playbackSessionId = _localTtsPlaybackSessionId + 1;
    _localTtsPlaybackSessionId = playbackSessionId;
    final int nowMs = DateTime.now().millisecondsSinceEpoch;
    final String textHash = _stableTextHash(trimmed);
    final bool looksDuplicate =
        textHash == _lastLocalTtsTextHash &&
        nowMs - _lastLocalTtsStartedAtMs < 15000;
    _lastLocalTtsTextHash = textHash;
    _lastLocalTtsStartedAtMs = nowMs;
    if (sanitized.removedCodePoints > 0) {
      _pocketTtsSanitizedRemovedTotal += sanitized.removedCodePoints;
      _writeTalkTextLog(
        'gen=$generation POCKET_TTS_SINGLE_SANITIZED removed='
        '${sanitized.removedCodePoints} raw="$rawTrimmed" clean="$trimmed"',
      );
    }
    _logTtsText(
      'PocketTTS request #$speakRequestId gen=$generation hash=$textHash'
      '${looksDuplicate ? ' DUPLICATE?' : ''}',
      trimmed,
    );
    if (_diagnosticsEnabled) {
      final String singleTtsLogLine = _formatTextChunkLogLine(
        id: speakRequestId,
        label: 'POCKET_TTS_SINGLE',
        text: trimmed,
      );
      _pocketTtsSpokenChunkLog = _appendBoundedTextLog(
        _pocketTtsSpokenChunkLog,
        singleTtsLogLine,
      );
      _pocketTtsFullSpokenInput = _appendTextWithSpace(
        _pocketTtsFullSpokenInput,
        trimmed,
      );
      _writeTalkTextLog('gen=$generation $singleTtsLogLine');
      developer.log(
        'PocketTTS request #$speakRequestId gen=$generation '
        'hash=$textHash duplicate=$looksDuplicate text="$trimmed"',
        name: 'StoryVaultTalk',
      );
    }
    final PersonaProfile? voicePersona = _activeVoicePersona();
    final String? referenceAudioPath = _cachedVoiceSamplePath(voicePersona);
    final double talkVoiceSpeed = await _currentTalkVoiceSpeed();
    final int talkVoicePrerollMs = await _currentTalkVoicePrerollMs();
    if (!mounted || generation != _assistantPlaybackGeneration) {
      return;
    }

    setState(() {
      _phase = CallPhase.speaking;
      _status = 'Speaking on device';
      _waitingForGeneratedWelcome = false;
      _pendingCallPersonaName = null;
      _metrics['tts_mode'] = 'client_text';
      _metrics['local_tts_model'] = 'pocket-tts-int8';
      _metrics['local_tts_steps'] = 6;
      _metrics['local_tts_speed'] = talkVoiceSpeed.toStringAsFixed(2);
      _metrics['local_tts_preroll_ms'] = talkVoicePrerollMs;
      _metrics['local_tts_request_id'] = speakRequestId;
      _metrics['local_tts_playback_session_id'] = playbackSessionId;
      _metrics['local_tts_text_hash'] = textHash;
      _metrics['local_tts_text_chars'] = trimmed.length;
      _metrics['local_tts_duplicate_recent'] = looksDuplicate;
      _metrics['local_tts_text_preview'] = _previewLogText(trimmed, limit: 96);
      _metrics['local_tts_voice_persona'] = voicePersona?.name;
      _metrics['local_tts_voice_sample_cached'] = referenceAudioPath != null;
      _metrics['local_tts_voice_asset_sha256'] = voicePersona?.voiceAssetSha256;
      _metrics['local_tts_voice_library_id'] = voicePersona?.voiceLibraryId;
      _metrics['pocket_tts_input'] = trimmed;
      _metrics['pocket_tts_input_chars'] = trimmed.length;
      if (sanitized.removedCodePoints > 0) {
        _metrics['pocket_tts_sanitized_removed_last'] =
            sanitized.removedCodePoints;
        _metrics['pocket_tts_sanitized_removed_total'] =
            _pocketTtsSanitizedRemovedTotal;
        _metrics['pocket_tts_last_raw_before_sanitize'] = rawTrimmed;
      }
      _metrics['pocket_tts_spoken_chunks'] = _pocketTtsSpokenChunkLog;
      _metrics['pocket_tts_full_spoken_input'] = _pocketTtsFullSpokenInput;
      _liveAudioCaption =
          'Speaking TTS: ${_previewLogText(trimmed, limit: 180)}';
    });

    try {
      final LocalPocketTtsResult result = await _localPocketTts.speak(
        trimmed,
        consistencySteps: 6,
        playbackSessionId: playbackSessionId,
        referenceAudioPath: referenceAudioPath,
        speed: talkVoiceSpeed,
        pcmPrerollMs: talkVoicePrerollMs,
        onProgress: (LocalPocketTtsPlaybackProgress progress) {
          _recordLocalTtsPlaybackProgress(
            progress,
            isCurrent: () =>
                mounted && generation == _assistantPlaybackGeneration,
            captionPrefix: 'Streaming TTS audio',
          );
        },
      );
      if (!mounted || generation != _assistantPlaybackGeneration) {
        _log(
          'PocketTTS request #$speakRequestId ignored after generation change',
        );
        return;
      }
      final int fallbackPlaybackWaitMs = _remainingLocalTtsPlaybackMs(
        result,
        includeTail: true,
      );
      final Map<String, dynamic> drainStatus =
          await _finishNativePlaybackStream(
            sessionId: playbackSessionId,
            fallbackWaitMs: fallbackPlaybackWaitMs,
            source: 'single',
          );
      if (!mounted || generation != _assistantPlaybackGeneration) {
        _log('PocketTTS request #$speakRequestId finished after interruption');
        return;
      }
      await _audio.stopPlayback(sessionId: playbackSessionId);
      if (!mounted || generation != _assistantPlaybackGeneration) {
        _log('PocketTTS request #$speakRequestId stopped after interruption');
        return;
      }
      final int nativeDrainMs =
          (drainStatus['waitMs'] as int?) ?? fallbackPlaybackWaitMs;
      setState(() {
        _metrics['local_tts_synthesis_s'] = result.synthesisTimeSeconds
            .toStringAsFixed(2);
        _metrics['local_tts_audio_s'] = result.audioDurationSeconds
            .toStringAsFixed(2);
        _metrics['local_tts_rtf'] = result.realtimeFactor.toStringAsFixed(2);
        _metrics['local_tts_chunks'] = result.chunks;
        _metrics['local_tts_bytes'] = result.audioBytes;
        _metrics['local_tts_native_drain_ms'] = nativeDrainMs;
        _metrics['local_tts_native_drained'] = drainStatus['drained'];
        _metrics['local_tts_native_timed_out'] = drainStatus['timedOut'];
        _metrics['local_tts_native_scheduled_buffers'] =
            drainStatus['scheduledBuffers'];
        _metrics['local_tts_native_played_buffers'] =
            drainStatus['playedBuffers'];
        _metrics['local_tts_native_pending_buffers'] =
            drainStatus['pendingBuffers'];
        _metrics['local_tts_native_scheduled_frames'] =
            drainStatus['scheduledFrames'];
        _metrics['local_tts_native_played_frames'] =
            drainStatus['playedFrames'];
        _metrics['local_tts_native_pending_frames'] =
            drainStatus['pendingFrames'];
        _metrics['local_tts_native_write_calls'] = drainStatus['writeCalls'];
        _metrics['local_tts_native_written_bytes'] =
            drainStatus['writtenBytes'];
        _metrics['local_tts_native_last_write_bytes'] =
            drainStatus['lastWriteBytes'];
        _metrics['local_tts_native_no_player_drops'] =
            drainStatus['droppedNoPlayerWrites'];
        _metrics['local_tts_native_dropped_writes'] =
            drainStatus['droppedStaleWrites'];
        _metrics['local_tts_native_drain_error'] =
            drainStatus['nativeDrainError'];
        _metrics['local_tts_native_fallback_wait_ms'] =
            drainStatus['fallbackWaitMs'];
        _metrics['local_tts_playback_wait_ms'] = nativeDrainMs;
        if (result.ttfaMilliseconds != null) {
          _metrics['local_tts_ttfa_ms'] = result.ttfaMilliseconds!.round();
        }
        _phase = CallPhase.ready;
        _status = 'Ready';
        _liveAudioCaption = '';
      });
      _log(
        'PocketTTS done #$speakRequestId chunks=${result.chunks} '
        'audio=${result.audioDurationSeconds.toStringAsFixed(2)}s '
        'synth=${result.synthesisTimeSeconds.toStringAsFixed(2)}s '
        'nativeDrain=${nativeDrainMs}ms',
      );
      if (_isConnected && _autoListenEnabled && !_disconnecting) {
        setState(() {
          _status = 'Preparing mic';
        });
        await Future<void>.delayed(
          const Duration(milliseconds: _localTtsMicSettleMs),
        );
        if (!mounted || generation != _assistantPlaybackGeneration) {
          return;
        }
        setState(() {
          _status = 'Opening mic';
        });
        await _startListening();
      } else {
        _scheduleConnectedIdleTimer();
      }
    } catch (error, stackTrace) {
      final String stackPreview = _previewLogText(
        stackTrace.toString(),
        limit: 360,
      );
      _log('Local PocketTTS failed: $error');
      _log('Local PocketTTS stack: $stackPreview');
      developer.log(
        'Local PocketTTS failed',
        name: 'StoryVaultTalk',
        error: error,
        stackTrace: stackTrace,
      );
      if (!mounted) {
        return;
      }
      setState(() {
        _phase = CallPhase.ready;
        _status = 'Local TTS failed';
        _metrics['local_tts_error'] = error.toString();
        _metrics['local_tts_stack'] = stackPreview;
        _liveAudioCaption = '';
      });
      _scheduleConnectedIdleTimer();
    }
  }

  Future<void> _stopAudioAndListen() async {
    await _stopAssistantAudio();
    if (mounted) {
      setState(() {
        _phase = CallPhase.ready;
        _status = 'Opening mic';
      });
    }
    await _startListening(assistantAlreadyStopped: true);
  }

  Future<void> _sendTextTurn() async {
    final String text = _textController.text.trim();
    if (text.isEmpty) {
      return;
    }
    if (!_isConnected) {
      await _connect();
    }
    if (!_isConnected) {
      return;
    }
    if (_turnRunning || _phase == CallPhase.speaking) {
      await _stopAssistantAudio();
    }
    _textController.clear();
    _sendServerTextTurn(text);
  }

  void _sendServerTextTurn(String text, {String? turnKind}) {
    final String trimmed = text.trim();
    if (trimmed.isEmpty) {
      return;
    }
    final Map<String, Object?> payload = <String, Object?>{
      'type': 'text_turn',
      'text': trimmed,
      'persona_id': _callPersonaName ?? _selectedPersona?.name,
      'tts_mode': _ttsMode,
    };
    if (turnKind != null && turnKind.trim().isNotEmpty) {
      payload['turn_kind'] = turnKind.trim();
    }
    _sendJson(payload);
  }

  void _beginLocalStreamingTts(int generation) {
    _cancelLocalStreamingTts(invalidateGeneration: false);
    _localTtsStreamGeneration = generation;
    _localTtsStreamBuffer = '';
    _localTtsFirstTokenAtMs = 0;
    _localTtsChunkSequence = 0;
    _localTtsChunksSpoken = 0;
    _localTtsStreamBytes = 0;
    _localTtsStreamChunks = 0;
    _localTtsPauseChunks = 0;
    _localTtsPauseBytes = 0;
    _localTtsPlaybackSessionId += 1;
    _localTtsSubtitleCursorMs = 0;
    _pocketTtsSanitizedRemovedTotal = 0;
    _localTtsStreamFinal = false;
    _localTtsQueueRunning = false;
    _localTtsDrainFuture = null;
    _localTtsQueue.clear();
    _localTtsChunkHashes.clear();
    _liveAudioCaption = '';
    _clearLiveSubtitleState(cancelTimer: true);
    if (mounted) {
      setState(() {
        _metrics['local_tts_streaming'] = true;
        _metrics['local_tts_playback_session_id'] = _localTtsPlaybackSessionId;
        _metrics['local_tts_startup_min_chars'] =
            _localTtsFirstSentenceMinChars;
        _metrics['local_tts_startup_max_chars'] = _localTtsFirstChunkMaxChars;
        _metrics['local_tts_startup_fallback_ms'] =
            _localTtsStartupFallbackWait.inMilliseconds;
        _metrics['local_tts_chunk_boundary'] =
            talkVoiceChunkBoundaryStorageValue(_talkVoiceChunkBoundary);
      });
    }
  }

  void _cancelLocalStreamingTts({bool invalidateGeneration = true}) {
    if (invalidateGeneration) {
      _localTtsStreamGeneration += 1;
    }
    _localTtsStreamFinal = true;
    _localTtsStreamBuffer = '';
    _localTtsQueue.clear();
    _localTtsChunkHashes.clear();
    _clearLiveSubtitleState(cancelTimer: true);
    _setLiveAudioCaption('');
    _signalLocalTtsQueue();
  }

  Future<void> _finishLocalStreamingTts(int generation) {
    if (generation != _localTtsStreamGeneration) {
      return Future<void>.value();
    }
    while (true) {
      final String? chunk = _takeLocalTtsStreamChunk(finalFlush: true);
      if (chunk == null) {
        break;
      }
      _enqueueLocalTtsChunk(chunk, generation, reason: 'final');
    }
    _localTtsStreamFinal = true;
    _signalLocalTtsQueue();
    _ensureLocalTtsQueueDraining(generation);
    return _localTtsDrainFuture ?? Future<void>.value();
  }

  String? _takeLocalTtsStreamChunk({required bool finalFlush}) {
    final String available = _localTtsStreamBuffer;
    if (available.trim().isEmpty) {
      if (finalFlush) {
        _localTtsStreamBuffer = '';
      }
      return null;
    }

    final bool firstChunk =
        _localTtsChunkSequence == 0 && _localTtsChunksSpoken == 0;
    final int minChars = firstChunk
        ? _localTtsFirstSentenceMinChars
        : _localTtsNextSentenceMinChars;
    final int maxChars = firstChunk
        ? _localTtsFirstChunkMaxChars
        : _localTtsNextChunkMaxChars;
    final int? boundaryEnd = _findLocalTtsBoundaryEnd(
      available,
      minChars: minChars,
      chunkBoundary: _talkVoiceChunkBoundary,
    );
    if (boundaryEnd != null && boundaryEnd <= _localTtsHardChunkMaxChars) {
      return _consumeLocalTtsPrefix(boundaryEnd);
    }

    final int trimmedLength = available.trim().length;
    if (!finalFlush) {
      final int nowMs = DateTime.now().millisecondsSinceEpoch;
      final bool startupFallbackReady =
          firstChunk &&
          _localTtsFirstTokenAtMs > 0 &&
          nowMs - _localTtsFirstTokenAtMs >=
              _localTtsStartupFallbackWait.inMilliseconds &&
          trimmedLength >= _localTtsStartupFallbackChars;
      if (startupFallbackReady) {
        return _consumeLocalTtsPrefix(
          _wordBoundaryForLocalTts(
            available,
            math.min(trimmedLength, maxChars),
          ),
        );
      }
      if (!startupFallbackReady && trimmedLength < maxChars) {
        return null;
      }
    }

    if (trimmedLength > _localTtsHardChunkMaxChars) {
      return _consumeLocalTtsPrefix(
        _wordBoundaryForLocalTts(available, _localTtsHardChunkMaxChars),
      );
    }
    if (finalFlush) {
      return _consumeLocalTtsPrefix(available.length);
    }
    return null;
  }

  int? _findLocalTtsBoundaryEnd(
    String text, {
    required int minChars,
    required TalkVoiceChunkBoundary chunkBoundary,
  }) {
    if (chunkBoundary == TalkVoiceChunkBoundary.paragraph) {
      return _findLocalTtsParagraphEnd(text, minChars: minChars);
    }
    return _findLocalTtsPunctuationEnd(
      text,
      minChars: minChars,
      chunkBoundary: chunkBoundary,
    );
  }

  int? _findLocalTtsPunctuationEnd(
    String text, {
    required int minChars,
    required TalkVoiceChunkBoundary chunkBoundary,
  }) {
    for (var i = 0; i < text.length; i += 1) {
      final int code = text.codeUnitAt(i);
      if (!_isWizardStoryBoundaryPunctuation(code, chunkBoundary)) {
        continue;
      }
      var end = i + 1;
      while (end < text.length) {
        final int next = text.codeUnitAt(end);
        if (next == 0x22 || next == 0x27 || next == 0x29 || next == 0x5d) {
          end += 1;
          continue;
        }
        break;
      }
      if (end < minChars) {
        continue;
      }
      if (end >= text.length || text.codeUnitAt(end) <= 0x20) {
        return end;
      }
    }
    return null;
  }

  int? _findLocalTtsParagraphEnd(String text, {required int minChars}) {
    final RegExp paragraphBreak = RegExp(r'\n\s*\n+');
    for (final RegExpMatch match in paragraphBreak.allMatches(text)) {
      final int end = match.end;
      if (end >= minChars) {
        return end;
      }
    }
    return null;
  }

  int _wordBoundaryForLocalTts(String text, int maxChars) {
    final int end = math.min(text.length, math.max(1, maxChars));
    final int minimum = math.max(1, (end * 0.55).round());
    for (var i = end; i > minimum; i -= 1) {
      if (text.codeUnitAt(i - 1) <= 0x20) {
        return i;
      }
    }
    return end;
  }

  String _consumeLocalTtsPrefix(int end) {
    final int safeEnd = math.min(
      math.max(0, end),
      _localTtsStreamBuffer.length,
    );
    final String chunk = _localTtsStreamBuffer.substring(0, safeEnd).trim();
    _localTtsStreamBuffer = _localTtsStreamBuffer.substring(safeEnd).trimLeft();
    return chunk;
  }

  void _enqueueLocalTtsChunk(
    String text,
    int generation, {
    required String reason,
    int pauseAfterMs = _localTtsInterChunkPauseMs,
  }) {
    if (generation != _localTtsStreamGeneration) {
      return;
    }
    final String rawNormalized = text.replaceAll(RegExp(r'\s+'), ' ').trim();
    final _SanitizedTtsText sanitized = _sanitizePocketTtsText(rawNormalized);
    final String normalized = _normalizeLocalTtsChunkText(sanitized.text);
    if (normalized.isEmpty) {
      return;
    }
    if (sanitized.removedCodePoints > 0) {
      _pocketTtsSanitizedRemovedTotal += sanitized.removedCodePoints;
      _writeTalkTextLog(
        'gen=$generation POCKET_TTS_SANITIZED removed='
        '${sanitized.removedCodePoints} raw="$rawNormalized" clean="$normalized"',
      );
      if (mounted) {
        setState(() {
          _metrics['pocket_tts_sanitized_removed_last'] =
              sanitized.removedCodePoints;
          _metrics['pocket_tts_sanitized_removed_total'] =
              _pocketTtsSanitizedRemovedTotal;
          _metrics['pocket_tts_last_raw_before_sanitize'] = rawNormalized;
        });
      }
    }
    final String hash = _stableTextHash(normalized);
    if (!_localTtsChunkHashes.add(hash)) {
      _log('Skipping duplicate TTS stream chunk hash=$hash');
      return;
    }
    final int id = _localTtsChunkSequence + 1;
    _localTtsChunkSequence = id;
    final _LocalTtsChunk localChunk = _LocalTtsChunk(
      id: id,
      text: normalized,
      hash: hash,
      subtitleWordCount: _countSubtitleWords(normalized),
      pauseAfterMs: math.max(0, pauseAfterMs),
    );
    _localTtsQueue.add(localChunk);
    _recordQueuedPocketTtsChunk(
      localChunk,
      generation: generation,
      reason: reason,
    );
    if (_localTtsFirstTokenAtMs > 0 && id == 1 && mounted) {
      setState(() {
        _metrics['local_tts_first_token_to_enqueue_ms'] =
            DateTime.now().millisecondsSinceEpoch - _localTtsFirstTokenAtMs;
      });
    }
    if (mounted) {
      setState(() {
        _metrics['local_tts_queued_chunks'] = _localTtsQueue.length;
        _metrics['local_tts_total_chunks'] = _localTtsChunkSequence;
        _metrics['local_tts_last_enqueue_reason'] = reason;
        _metrics['local_tts_last_pause_after_ms'] = localChunk.pauseAfterMs;
        _metrics['pocket_tts_last_queued_input'] = normalized;
        _metrics['pocket_tts_last_queued_chars'] = normalized.length;
        _metrics['pocket_tts_full_queued_input'] = _pocketTtsFullQueuedInput;
        _liveAudioCaption =
            'Queued TTS #$id: ${_previewLogText(normalized, limit: 180)}';
      });
    }
    _logTtsText('Queued TTS chunk #$id reason=$reason hash=$hash', normalized);
    _signalLocalTtsQueue();
    _ensureLocalTtsQueueDraining(generation);
  }

  String _normalizeLocalTtsChunkText(String text) {
    final String normalized = text.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (normalized.isEmpty) {
      return '';
    }
    final int last = normalized.codeUnitAt(normalized.length - 1);
    if (last == 0x2e || last == 0x21 || last == 0x3f) {
      return normalized;
    }
    return '$normalized.';
  }

  _SanitizedTtsText _sanitizePocketTtsText(String text) {
    if (text.isEmpty) {
      return const _SanitizedTtsText(text: '', removedCodePoints: 0);
    }
    final String markdownCleaned = _stripPocketTtsMarkdown(text);
    var removed = text.runes.length - markdownCleaned.runes.length;
    final StringBuffer buffer = StringBuffer();
    for (final int rune in markdownCleaned.runes) {
      if (_isUnsupportedPocketTtsRune(rune)) {
        removed += 1;
        continue;
      }
      switch (rune) {
        case 0x2018:
        case 0x2019:
          buffer.write("'");
        case 0x201C:
        case 0x201D:
          buffer.write('"');
        case 0x2013:
        case 0x2014:
          buffer.write('-');
        case 0x2026:
          buffer.write('...');
        default:
          buffer.writeCharCode(rune);
      }
    }
    return _SanitizedTtsText(
      text: buffer.toString().replaceAll(RegExp(r'\s+'), ' ').trim(),
      removedCodePoints: removed,
    );
  }

  String _stripPocketTtsMarkdown(String text) {
    var cleaned = text;
    cleaned = cleaned.replaceAllMapped(
      RegExp(r'\*\*([^*]+)\*\*'),
      (Match match) => match.group(1) ?? '',
    );
    cleaned = cleaned.replaceAllMapped(
      RegExp(r'__([^_]+)__'),
      (Match match) => match.group(1) ?? '',
    );
    cleaned = cleaned.replaceAllMapped(
      RegExp(r'\*([^*]+)\*'),
      (Match match) => match.group(1) ?? '',
    );
    cleaned = cleaned.replaceAllMapped(
      RegExp(r'_([^_]+)_'),
      (Match match) => match.group(1) ?? '',
    );
    cleaned = cleaned.replaceAllMapped(
      RegExp(r'`([^`]+)`'),
      (Match match) => match.group(1) ?? '',
    );
    cleaned = cleaned.replaceAll(RegExp(r'(^|\s)[*_`]+(?=\s|$)'), ' ');
    cleaned = cleaned.replaceAll(
      RegExp(r'^[ \t]*[-*+][ \t]+', multiLine: true),
      '',
    );
    return cleaned;
  }

  bool _isUnsupportedPocketTtsRune(int rune) {
    if (rune == 0x200D || rune == 0xFE0E || rune == 0xFE0F || rune == 0x20E3) {
      return true;
    }
    if (rune >= 0xE0020 && rune <= 0xE007F) {
      return true;
    }
    if (rune >= 0x1F000 && rune <= 0x1FAFF) {
      return true;
    }
    if (rune >= 0x2300 && rune <= 0x23FF) {
      return true;
    }
    if (rune >= 0x2600 && rune <= 0x27BF) {
      return true;
    }
    if (rune >= 0x2B00 && rune <= 0x2BFF) {
      return true;
    }
    return false;
  }

  void _ensureLocalTtsQueueDraining(int generation) {
    if (_localTtsQueueRunning || generation != _localTtsStreamGeneration) {
      return;
    }
    final Future<void> drainFuture = _drainLocalTtsQueue(generation);
    _localTtsDrainFuture = drainFuture;
  }

  Future<void> _drainLocalTtsQueue(int generation) async {
    _localTtsQueueRunning = true;
    try {
      while (mounted && generation == _localTtsStreamGeneration) {
        if (_localTtsQueue.isEmpty) {
          if (_localTtsStreamFinal) {
            break;
          }
          await _waitForLocalTtsQueueSignal();
          continue;
        }
        final _LocalTtsChunk chunk = _localTtsQueue.removeAt(0);
        await _speakLocalTtsChunk(
          chunk,
          generation,
          restartPlayback: _localTtsChunksSpoken == 0,
        );
        final bool shouldInsertPause =
            mounted &&
            generation == _localTtsStreamGeneration &&
            (_localTtsQueue.isNotEmpty || !_localTtsStreamFinal);
        if (shouldInsertPause && chunk.pauseAfterMs > 0) {
          await _insertLocalTtsInterChunkPause(
            generation,
            pauseMs: chunk.pauseAfterMs,
          );
        }
      }
      if (mounted && generation == _localTtsStreamGeneration) {
        await _finishLocalStreamingPlayback(generation);
      }
    } catch (error, stackTrace) {
      final String stackPreview = _previewLogText(
        stackTrace.toString(),
        limit: 360,
      );
      _log('Streaming PocketTTS failed: $error');
      _log('Streaming PocketTTS stack: $stackPreview');
      developer.log(
        'Streaming PocketTTS failed',
        name: 'StoryVaultTalk',
        error: error,
        stackTrace: stackTrace,
      );
      if (mounted && generation == _localTtsStreamGeneration) {
        setState(() {
          _phase = CallPhase.ready;
          _status = 'Local TTS failed';
          _metrics['local_tts_error'] = error.toString();
          _metrics['local_tts_stack'] = stackPreview;
        });
        _scheduleConnectedIdleTimer();
      }
    } finally {
      if (generation == _localTtsStreamGeneration) {
        _localTtsQueueRunning = false;
      }
    }
  }

  Future<void> _speakLocalTtsChunk(
    _LocalTtsChunk chunk,
    int generation, {
    required bool restartPlayback,
  }) async {
    if (!mounted || generation != _localTtsStreamGeneration) {
      return;
    }
    final int speakRequestId = _localTtsSpeakRequestId + 1;
    _localTtsSpeakRequestId = speakRequestId;
    _logTtsText(
      'PocketTTS stream request #$speakRequestId chunk=${chunk.id} '
      'gen=$generation hash=${chunk.hash}',
      chunk.text,
    );
    _recordSpokenPocketTtsChunk(chunk, generation);
    final PersonaProfile? voicePersona = _activeVoicePersona();
    final String? referenceAudioPath = _cachedVoiceSamplePath(voicePersona);
    final double talkVoiceSpeed = await _currentTalkVoiceSpeed();
    final int talkVoicePrerollMs = await _currentTalkVoicePrerollMs();
    if (!mounted || generation != _localTtsStreamGeneration) {
      return;
    }
    _scheduleLiveSubtitleForChunk(chunk, generation, speed: talkVoiceSpeed);
    setState(() {
      _phase = CallPhase.speaking;
      _status = 'Speaking on device';
      _waitingForGeneratedWelcome = false;
      _pendingCallPersonaName = null;
      _metrics['tts_mode'] = 'client_text';
      _metrics['local_tts_model'] = 'pocket-tts-int8';
      _metrics['local_tts_steps'] = 6;
      _metrics['local_tts_speed'] = talkVoiceSpeed.toStringAsFixed(2);
      _metrics['local_tts_preroll_ms'] = talkVoicePrerollMs;
      _metrics['local_tts_request_id'] = speakRequestId;
      _metrics['local_tts_chunk_id'] = chunk.id;
      _metrics['local_tts_text_hash'] = chunk.hash;
      _metrics['local_tts_text_chars'] = chunk.text.length;
      _metrics['local_tts_text_preview'] = _previewLogText(
        chunk.text,
        limit: 96,
      );
      _metrics['local_tts_voice_persona'] = voicePersona?.name;
      _metrics['local_tts_voice_sample_cached'] = referenceAudioPath != null;
      _metrics['local_tts_voice_asset_sha256'] = voicePersona?.voiceAssetSha256;
      _metrics['local_tts_voice_library_id'] = voicePersona?.voiceLibraryId;
      _metrics['pocket_tts_input'] = chunk.text;
      _metrics['pocket_tts_input_chars'] = chunk.text.length;
      _metrics['pocket_tts_full_spoken_input'] = _pocketTtsFullSpokenInput;
      _metrics['local_tts_queued_chunks'] = _localTtsQueue.length;
      _liveAudioCaption =
          'Speaking TTS #${chunk.id}: ${_previewLogText(chunk.text, limit: 180)}';
    });

    final LocalPocketTtsResult result = await _localPocketTts.speak(
      chunk.text,
      consistencySteps: 6,
      restartPlayback: restartPlayback,
      playbackSessionId: _localTtsPlaybackSessionId,
      referenceAudioPath: referenceAudioPath,
      speed: talkVoiceSpeed,
      pcmPrerollMs: talkVoicePrerollMs,
      onProgress: (LocalPocketTtsPlaybackProgress progress) {
        _recordLocalTtsPlaybackProgress(
          progress,
          isCurrent: () => mounted && generation == _localTtsStreamGeneration,
          captionPrefix: 'Streaming TTS #${chunk.id}',
        );
      },
    );
    if (!mounted || generation != _localTtsStreamGeneration) {
      _log('PocketTTS stream request #$speakRequestId ignored after cancel');
      return;
    }

    _retimeLiveSubtitleForChunk(
      chunk,
      generation,
      actualDurationMs: (result.audioDurationSeconds * 1000).round(),
    );
    _localTtsChunksSpoken += 1;
    _localTtsStreamBytes += result.audioBytes;
    _localTtsStreamChunks += result.chunks;
    final int remainingPlaybackMs = _remainingLocalTtsPlaybackMs(
      result,
      includeTail: false,
    );
    final int nowMs = DateTime.now().millisecondsSinceEpoch;
    if (_assistantPlaybackEndsAtMs < nowMs) {
      _assistantPlaybackEndsAtMs = nowMs;
    }
    _assistantPlaybackEndsAtMs += remainingPlaybackMs;
    setState(() {
      _metrics['local_tts_spoken_chunks'] = _localTtsChunksSpoken;
      _metrics['local_tts_stream_chunks'] = _localTtsStreamChunks;
      _metrics['local_tts_stream_bytes'] = _localTtsStreamBytes;
      _metrics['local_tts_synthesis_s'] = result.synthesisTimeSeconds
          .toStringAsFixed(2);
      _metrics['local_tts_audio_s'] = result.audioDurationSeconds
          .toStringAsFixed(2);
      _metrics['local_tts_rtf'] = result.realtimeFactor.toStringAsFixed(2);
      _metrics['local_tts_chunks'] = result.chunks;
      _metrics['local_tts_bytes'] = result.audioBytes;
      _metrics['local_tts_playback_wait_ms'] = remainingPlaybackMs;
      if (result.ttfaMilliseconds != null) {
        _metrics['local_tts_ttfa_ms'] = result.ttfaMilliseconds!.round();
      }
    });
    _log(
      'PocketTTS stream done #$speakRequestId chunk=${chunk.id} '
      'audio=${result.audioDurationSeconds.toStringAsFixed(2)}s '
      'synth=${result.synthesisTimeSeconds.toStringAsFixed(2)}s '
      'queued=${_localTtsQueue.length}',
    );
  }

  Future<void> _insertLocalTtsInterChunkPause(
    int generation, {
    required int pauseMs,
  }) async {
    if (!mounted ||
        generation != _localTtsStreamGeneration ||
        _localTtsPlaybackSessionId <= 0) {
      return;
    }
    final int safePauseMs = math.max(0, pauseMs);
    if (safePauseMs == 0) {
      return;
    }
    final int sampleCount = (_outputSampleRate * safePauseMs / 1000).round();
    final Uint8List silencePcm16 = Uint8List(sampleCount * 2);
    await _audio.writePlayback(
      silencePcm16,
      sessionId: _localTtsPlaybackSessionId,
    );
    if (!mounted || generation != _localTtsStreamGeneration) {
      return;
    }
    final int nowMs = DateTime.now().millisecondsSinceEpoch;
    if (_assistantPlaybackEndsAtMs < nowMs) {
      _assistantPlaybackEndsAtMs = nowMs;
    }
    _assistantPlaybackEndsAtMs += safePauseMs;
    _localTtsSubtitleCursorMs += safePauseMs;
    _localTtsPauseChunks += 1;
    _localTtsPauseBytes += silencePcm16.length;
    setState(() {
      _metrics['local_tts_inter_chunk_pause_ms'] = safePauseMs;
      _metrics['local_tts_pause_chunks'] = _localTtsPauseChunks;
      _metrics['local_tts_pause_bytes'] = _localTtsPauseBytes;
      _metrics['local_tts_playback_wait_ms'] = math.max(
        0,
        _assistantPlaybackEndsAtMs - nowMs,
      );
    });
  }

  void _scheduleLiveSubtitleForChunk(
    _LocalTtsChunk chunk,
    int generation, {
    required double speed,
  }) {
    if (!mounted || generation != _localTtsStreamGeneration) {
      return;
    }
    final int nowMs = DateTime.now().millisecondsSinceEpoch;
    final int startMs = math.max(nowMs, _localTtsSubtitleCursorMs);
    final int durationMs = _estimateSubtitleDurationMs(
      chunk.subtitleWordCount,
      speed: speed,
    );
    _localTtsSubtitleCursorMs = startMs + durationMs;
    _liveSubtitleGeneration = generation;
    _liveSubtitleSchedule.add(
      _LiveSubtitleSegment(
        chunkId: chunk.id,
        text: chunk.text,
        wordCount: chunk.subtitleWordCount,
        startMs: startMs,
        durationMs: durationMs,
      ),
    );
    _subtitleHighlightTimer ??= Timer.periodic(
      const Duration(milliseconds: 90),
      (_) => _updateLiveSubtitleHighlight(),
    );
    setState(() {
      _metrics['live_subtitle_scheduled_chunk_id'] = chunk.id;
      _metrics['live_subtitle_scheduled_words'] = chunk.subtitleWordCount;
      _metrics['live_subtitle_scheduled_start_ms'] = startMs;
      _metrics['live_subtitle_estimated_ms'] = durationMs;
      _metrics['live_subtitle_schedule_size'] = _liveSubtitleSchedule.length;
    });
    _updateLiveSubtitleHighlight();
  }

  void _retimeLiveSubtitleForChunk(
    _LocalTtsChunk chunk,
    int generation, {
    required int actualDurationMs,
  }) {
    if (generation != _liveSubtitleGeneration || actualDurationMs <= 0) {
      return;
    }
    final int segmentIndex = _liveSubtitleSchedule.indexWhere(
      (_LiveSubtitleSegment segment) => segment.chunkId == chunk.id,
    );
    if (segmentIndex < 0) {
      return;
    }
    final _LiveSubtitleSegment segment = _liveSubtitleSchedule[segmentIndex];
    final int safeDurationMs = math.max(650, actualDurationMs);
    final int oldEndMs = segment.endMs;
    segment.durationMs = safeDurationMs;
    final int newEndMs = segment.endMs;
    final int deltaMs = newEndMs - oldEndMs;
    if (deltaMs != 0) {
      for (
        var index = segmentIndex + 1;
        index < _liveSubtitleSchedule.length;
        index += 1
      ) {
        _liveSubtitleSchedule[index].startMs += deltaMs;
      }
    }
    if (_localTtsSubtitleCursorMs >= oldEndMs) {
      _localTtsSubtitleCursorMs += deltaMs;
    }
    if (mounted) {
      setState(() {
        _metrics['live_subtitle_actual_ms'] = safeDurationMs;
        _metrics['live_subtitle_retimed_chunk_id'] = chunk.id;
      });
    }
    _updateLiveSubtitleHighlight();
  }

  int _estimateSubtitleDurationMs(int wordCount, {required double speed}) {
    final int safeWordCount = math.max(1, wordCount);
    final double safeSpeed = clampTalkVoiceSpeed(speed) * 0.8;
    final int estimate = ((safeWordCount * 380 + 320) / safeSpeed).round();
    return estimate.clamp(850, 22000).toInt();
  }

  int _countSubtitleWords(String text) {
    return text
        .split(RegExp(r'\s+'))
        .where((String value) => value.trim().isNotEmpty)
        .length;
  }

  void _updateLiveSubtitleHighlight() {
    if (!mounted ||
        _liveSubtitleGeneration != _localTtsStreamGeneration ||
        _liveSubtitleSchedule.isEmpty) {
      return;
    }
    final int nowMs = DateTime.now().millisecondsSinceEpoch;
    _LiveSubtitleSegment? displayedSegment;
    for (final _LiveSubtitleSegment segment in _liveSubtitleSchedule) {
      if (nowMs < segment.startMs) {
        break;
      }
      displayedSegment = segment;
      if (nowMs < segment.endMs) {
        break;
      }
    }
    if (displayedSegment == null || displayedSegment.wordCount <= 0) {
      return;
    }
    final _LiveSubtitleSegment segment = displayedSegment;
    final int elapsedMs = nowMs - segment.startMs;
    final int nextWordIndex;
    if (elapsedMs < 0 || elapsedMs >= segment.durationMs) {
      nextWordIndex = -1;
    } else {
      final double progress = (elapsedMs / segment.durationMs).clamp(
        0.0,
        0.999,
      );
      nextWordIndex = math.min(
        segment.wordCount - 1,
        (progress * segment.wordCount).floor(),
      );
    }
    if (segment.chunkId == _liveSubtitleChunkId &&
        nextWordIndex == _liveSubtitleActiveWordIndex &&
        segment.text == _liveSubtitleText) {
      return;
    }
    setState(() {
      _liveSubtitleText = segment.text;
      _liveSubtitleActiveWordIndex = nextWordIndex;
      _liveSubtitleChunkId = segment.chunkId;
      _metrics['live_subtitle_chunk_id'] = segment.chunkId;
      _metrics['live_subtitle_words'] = segment.wordCount;
      _metrics['live_subtitle_active_word'] = nextWordIndex;
    });
  }

  void _clearLiveSubtitleState({required bool cancelTimer}) {
    if (cancelTimer) {
      _subtitleHighlightTimer?.cancel();
      _subtitleHighlightTimer = null;
    }
    _liveSubtitleText = '';
    _liveSubtitleActiveWordIndex = -1;
    _liveSubtitleGeneration = 0;
    _liveSubtitleChunkId = 0;
    _liveSubtitleSchedule.clear();
  }

  void _recordLocalTtsPlaybackProgress(
    LocalPocketTtsPlaybackProgress progress, {
    required bool Function() isCurrent,
    required String captionPrefix,
  }) {
    if (!mounted || !isCurrent()) {
      return;
    }
    final Map<String, dynamic> nativeStatus =
        progress.nativeStatus ?? const <String, dynamic>{};
    setState(() {
      _metrics['local_tts_live_chunk'] = progress.chunkIndex;
      _metrics['local_tts_live_sample_rate'] = progress.sampleRate;
      _metrics['local_tts_live_samples'] = progress.samples;
      _metrics['local_tts_live_pcm_bytes'] = progress.pcmBytes;
      _metrics['local_tts_live_total_pcm_bytes'] = progress.totalPcmBytes;
      _metrics['local_tts_gain'] = progress.normalizationGain.toStringAsFixed(
        2,
      );
      _metrics['local_tts_source_rms'] = progress.sourceRms.toStringAsFixed(4);
      _metrics['local_tts_source_peak'] = progress.sourcePeak.toStringAsFixed(
        4,
      );
      if (progress.ttfaMilliseconds != null) {
        _metrics['local_tts_live_ttfa_ms'] = progress.ttfaMilliseconds!.round();
      }
      _metrics['local_tts_native_session_id'] = nativeStatus['sessionId'];
      _metrics['local_tts_native_playing'] = nativeStatus['playing'];
      _metrics['local_tts_native_stream_closed'] = nativeStatus['streamClosed'];
      _metrics['local_tts_native_scheduled_buffers'] =
          nativeStatus['scheduledBuffers'];
      _metrics['local_tts_native_played_buffers'] =
          nativeStatus['playedBuffers'];
      _metrics['local_tts_native_pending_buffers'] =
          nativeStatus['pendingBuffers'];
      _metrics['local_tts_native_scheduled_frames'] =
          nativeStatus['scheduledFrames'];
      _metrics['local_tts_native_played_frames'] = nativeStatus['playedFrames'];
      _metrics['local_tts_native_pending_frames'] =
          nativeStatus['pendingFrames'];
      _metrics['local_tts_native_input_sample_rate'] =
          nativeStatus['inputSampleRate'];
      _metrics['local_tts_native_output_sample_rate'] =
          nativeStatus['outputSampleRate'];
      _metrics['local_tts_native_resampler'] = nativeStatus['resampler'];
      _metrics['local_tts_native_resample_calls'] =
          nativeStatus['resampleCalls'];
      _metrics['local_tts_native_resample_total_ms'] =
          nativeStatus['resampleTotalMs'];
      _metrics['local_tts_native_resample_last_ms'] =
          nativeStatus['resampleLastMs'];
      _metrics['local_tts_native_eq_enabled'] = nativeStatus['eqEnabled'];
      _metrics['local_tts_native_eq_preset'] = nativeStatus['eqPreset'];
      _metrics['local_tts_native_write_calls'] = nativeStatus['writeCalls'];
      _metrics['local_tts_native_written_bytes'] = nativeStatus['writtenBytes'];
      _metrics['local_tts_native_last_write_bytes'] =
          nativeStatus['lastWriteBytes'];
      _metrics['local_tts_native_no_player_drops'] =
          nativeStatus['droppedNoPlayerWrites'];
      _metrics['local_tts_native_dropped_writes'] =
          nativeStatus['droppedStaleWrites'];
      _metrics['local_tts_native_status_error'] =
          nativeStatus['playbackStatusError'];
      _liveAudioCaption =
          '$captionPrefix audio #${progress.chunkIndex}: '
          '${_formatBytes(progress.totalPcmBytes)}';
    });
  }

  Future<Map<String, dynamic>> _finishNativePlaybackStream({
    required int sessionId,
    required int fallbackWaitMs,
    required String source,
  }) async {
    final Stopwatch stopwatch = Stopwatch()..start();
    try {
      final Map<String, dynamic> status = Map<String, dynamic>.from(
        await _audio.finishPlaybackStream(
          sessionId: sessionId,
          timeoutMs: _localTtsPlaybackDrainTimeoutMs,
        ),
      );
      stopwatch.stop();
      status['waitMs'] ??= stopwatch.elapsedMilliseconds;
      status['nativeDrainError'] = null;
      status['fallbackWaitMs'] = 0;
      return status;
    } catch (error, stackTrace) {
      stopwatch.stop();
      _log('Native playback drain failed ($source): $error');
      developer.log(
        'Native playback drain failed source=$source session=$sessionId',
        name: 'StoryVaultTalk',
        error: error,
        stackTrace: stackTrace,
      );
      final int safeFallbackWaitMs = math.max(0, fallbackWaitMs);
      if (safeFallbackWaitMs > 0) {
        await Future<void>.delayed(Duration(milliseconds: safeFallbackWaitMs));
      }
      return <String, dynamic>{
        'sessionId': sessionId,
        'drained': false,
        'timedOut': false,
        'stopped': false,
        'stale': false,
        'waitMs': stopwatch.elapsedMilliseconds + safeFallbackWaitMs,
        'fallbackWaitMs': safeFallbackWaitMs,
        'scheduledBuffers': null,
        'playedBuffers': null,
        'pendingBuffers': null,
        'scheduledFrames': null,
        'playedFrames': null,
        'pendingFrames': null,
        'writeCalls': null,
        'writtenBytes': null,
        'lastWriteBytes': null,
        'droppedNoPlayerWrites': null,
        'droppedStaleWrites': null,
        'nativeDrainError': error.toString(),
      };
    }
  }

  int _remainingLocalTtsPlaybackMs(
    LocalPocketTtsResult result, {
    required bool includeTail,
  }) {
    final double ttfaSeconds = (result.ttfaMilliseconds ?? 0) / 1000;
    final double playedDuringSynthesisSeconds = math.max(
      0,
      result.synthesisTimeSeconds - ttfaSeconds,
    );
    final double remainingAudioSeconds = math.max(
      0,
      result.audioDurationSeconds - playedDuringSynthesisSeconds,
    );
    return (remainingAudioSeconds * 1000).round() +
        (includeTail ? _localTtsPlaybackTailMs : 0);
  }

  Future<void> _finishLocalStreamingPlayback(int generation) async {
    if (_localTtsChunksSpoken <= 0) {
      _clearLiveSubtitleState(cancelTimer: true);
      _setLiveAudioCaption('');
      _scheduleConnectedIdleTimer();
      return;
    }
    final int playbackSessionId = _localTtsPlaybackSessionId;
    final int nowMs = DateTime.now().millisecondsSinceEpoch;
    final int fallbackPlaybackWaitMs = math.max(
      0,
      _assistantPlaybackEndsAtMs - nowMs + _localTtsPlaybackTailMs,
    );
    final Map<String, dynamic> drainStatus = await _finishNativePlaybackStream(
      sessionId: playbackSessionId,
      fallbackWaitMs: fallbackPlaybackWaitMs,
      source: 'stream',
    );
    if (mounted) {
      setState(() {
        _metrics['local_tts_native_drain_ms'] = drainStatus['waitMs'];
        _metrics['local_tts_native_drained'] = drainStatus['drained'];
        _metrics['local_tts_native_timed_out'] = drainStatus['timedOut'];
        _metrics['local_tts_native_scheduled_buffers'] =
            drainStatus['scheduledBuffers'];
        _metrics['local_tts_native_played_buffers'] =
            drainStatus['playedBuffers'];
        _metrics['local_tts_native_pending_buffers'] =
            drainStatus['pendingBuffers'];
        _metrics['local_tts_native_scheduled_frames'] =
            drainStatus['scheduledFrames'];
        _metrics['local_tts_native_played_frames'] =
            drainStatus['playedFrames'];
        _metrics['local_tts_native_pending_frames'] =
            drainStatus['pendingFrames'];
        _metrics['local_tts_native_input_sample_rate'] =
            drainStatus['inputSampleRate'];
        _metrics['local_tts_native_output_sample_rate'] =
            drainStatus['outputSampleRate'];
        _metrics['local_tts_native_resampler'] = drainStatus['resampler'];
        _metrics['local_tts_native_resample_calls'] =
            drainStatus['resampleCalls'];
        _metrics['local_tts_native_resample_total_ms'] =
            drainStatus['resampleTotalMs'];
        _metrics['local_tts_native_resample_last_ms'] =
            drainStatus['resampleLastMs'];
        _metrics['local_tts_native_eq_enabled'] = drainStatus['eqEnabled'];
        _metrics['local_tts_native_eq_preset'] = drainStatus['eqPreset'];
        _metrics['local_tts_native_write_calls'] = drainStatus['writeCalls'];
        _metrics['local_tts_native_written_bytes'] =
            drainStatus['writtenBytes'];
        _metrics['local_tts_native_last_write_bytes'] =
            drainStatus['lastWriteBytes'];
        _metrics['local_tts_native_no_player_drops'] =
            drainStatus['droppedNoPlayerWrites'];
        _metrics['local_tts_native_dropped_writes'] =
            drainStatus['droppedStaleWrites'];
        _metrics['local_tts_native_drain_error'] =
            drainStatus['nativeDrainError'];
        _metrics['local_tts_native_fallback_wait_ms'] =
            drainStatus['fallbackWaitMs'];
      });
    }
    if (!mounted || generation != _localTtsStreamGeneration) {
      return;
    }
    await _audio.stopPlayback(sessionId: playbackSessionId);
    if (!mounted || generation != _localTtsStreamGeneration) {
      return;
    }
    _clearLiveSubtitleState(cancelTimer: true);
    setState(() {
      _phase = CallPhase.ready;
      _status = 'Ready';
      _liveAudioCaption = '';
    });
    if (_isConnected && _autoListenEnabled && !_disconnecting) {
      setState(() {
        _status = 'Preparing mic';
      });
      await Future<void>.delayed(
        const Duration(milliseconds: _localTtsMicSettleMs),
      );
      if (!mounted || generation != _localTtsStreamGeneration) {
        return;
      }
      setState(() {
        _status = 'Opening mic';
      });
      await _startListening();
    } else {
      _scheduleConnectedIdleTimer();
    }
  }

  Future<void> _waitForLocalTtsQueueSignal() {
    final Completer<void> completer = _localTtsQueueSignal ??=
        Completer<void>();
    return completer.future;
  }

  void _signalLocalTtsQueue() {
    final Completer<void>? completer = _localTtsQueueSignal;
    _localTtsQueueSignal = null;
    if (completer != null && !completer.isCompleted) {
      completer.complete();
    }
  }

  Future<void> _handleMainButtonTap() async {
    switch (_phase) {
      case CallPhase.disconnected:
        await _connect();
      case CallPhase.connecting:
        break;
      case CallPhase.listening:
        await _stopListening();
      case CallPhase.ready:
      case CallPhase.thinking:
      case CallPhase.speaking:
        await _startListening();
    }
  }

  void _resetAssistantPlaybackTracking() {
    _cancelAssistantPlaybackTimer();
    _assistantPlaybackGeneration += 1;
    _assistantPlaybackEndsAtMs = 0;
    if (mounted) {
      setState(() {
        _metrics.remove('assistant_audio_scheduled_ms');
      });
    }
  }

  void _scheduleAssistantPlaybackDone({
    int cushionMs = _assistantPlaybackDoneCushionMs,
  }) {
    if (!_isConnected || !_autoListenEnabled) {
      return;
    }
    final int generation = _assistantPlaybackGeneration;
    final int now = DateTime.now().millisecondsSinceEpoch;
    final int delayMs = math.max(
      80,
      _assistantPlaybackEndsAtMs - now + cushionMs,
    );
    _assistantPlaybackDoneTimer?.cancel();
    _assistantPlaybackDoneTimer = Timer(Duration(milliseconds: delayMs), () {
      unawaited(_handleAssistantPlaybackDone(generation));
    });
  }

  void _cancelAssistantPlaybackTimer() {
    _assistantPlaybackDoneTimer?.cancel();
    _assistantPlaybackDoneTimer = null;
  }

  Future<void> _handleAssistantPlaybackDone(int generation) async {
    if (!mounted ||
        !_isConnected ||
        !_autoListenEnabled ||
        _disconnecting ||
        generation != _assistantPlaybackGeneration ||
        _turnRunning ||
        _phase == CallPhase.listening) {
      return;
    }
    setState(() {
      _phase = CallPhase.ready;
      _status = 'Opening mic';
    });
    _log('Assistant audio finished; opening mic');
    await _startListening();
  }

  void _sendMicFrame(Uint8List frame) {
    final WebSocket? socket = _socket;
    final bool captureLocally = _usesDeviceAsrForTurn;
    if (captureLocally) {
      final bool firstSentFrame = _micFramesSent == _listenStartMicFrames;
      _localSpeechFrames.add(Uint8List.fromList(frame));
      _micBytes += frame.length;
      _micFramesSent += 1;
      if (firstSentFrame) {
        _log('Mic frames captured locally');
      }
      return;
    }
    if (socket == null) {
      return;
    }
    final bool firstSentFrame = _micFramesSent == _listenStartMicFrames;
    try {
      socket.add(frame);
    } catch (error) {
      _log('Mic send failed: $error');
      return;
    }
    _micBytes += frame.length;
    _micFramesSent += 1;
    if (firstSentFrame) {
      _log('Mic frames flowing');
    }
  }

  void _bufferPreSpeechFrame(Uint8List frame) {
    _preSpeechFrames.add(Uint8List.fromList(frame));
    _preSpeechBytes += frame.length;
    final int maxBytes = math.max(
      1,
      (_inputSampleRate * 2 * _preSpeechBufferMs / 1000).round(),
    );
    while (_preSpeechBytes > maxBytes && _preSpeechFrames.isNotEmpty) {
      _preSpeechBytes -= _preSpeechFrames.removeAt(0).length;
    }
  }

  void _bufferLocalFallbackFrame(Uint8List frame) {
    _localFallbackFrames.add(Uint8List.fromList(frame));
    _localFallbackBytes += frame.length;
    final int maxBytes = math.max(
      1,
      (_inputSampleRate * 2 * _firstVoiceTimeout.inMilliseconds / 1000).round(),
    );
    while (_localFallbackBytes > maxBytes && _localFallbackFrames.isNotEmpty) {
      _localFallbackBytes -= _localFallbackFrames.removeAt(0).length;
    }
  }

  void _useLocalFallbackFrames() {
    if (_localFallbackFrames.isEmpty) {
      _flushPreSpeechFrames();
      return;
    }
    _localSpeechFrames
      ..clear()
      ..addAll(_localFallbackFrames.map(Uint8List.fromList));
    _localFallbackFrames.clear();
    _localFallbackBytes = 0;
    _preSpeechFrames.clear();
    _preSpeechBytes = 0;
  }

  void _clearLocalCaptureBuffers() {
    _localSpeechFrames.clear();
    _localFallbackFrames.clear();
    _preSpeechFrames.clear();
    _localFallbackBytes = 0;
    _preSpeechBytes = 0;
  }

  void _flushPreSpeechFrames() {
    for (final Uint8List frame in _preSpeechFrames) {
      _sendMicFrame(frame);
    }
    _preSpeechFrames.clear();
    _preSpeechBytes = 0;
  }

  void _scheduleFirstVoiceTimeout() {
    _listeningTimeoutTimer?.cancel();
    _listeningTimeoutTimer = Timer(_firstVoiceTimeout, () {
      unawaited(_handleFirstVoiceTimeout());
    });
  }

  void _schedulePostVoiceSilenceTimeout() {
    _listeningTimeoutTimer?.cancel();
    _listeningTimeoutTimer = Timer(_postVoiceSilenceTimeout, () {
      unawaited(_handlePostVoiceSilenceTimeout());
    });
  }

  void _cancelListeningTimeout() {
    _listeningTimeoutTimer?.cancel();
    _listeningTimeoutTimer = null;
  }

  Future<void> _handleFirstVoiceTimeout() async {
    if (!mounted ||
        !_isConnected ||
        _phase != CallPhase.listening ||
        _voiceStarted) {
      return;
    }
    if (_usesDeviceAsrForTurn) {
      _log(
        'No client VAD trigger; transcribing buffered audio with Sherpa Whisper',
      );
      _useLocalFallbackFrames();
      await _stopListening();
      return;
    }
    _sendJson(<String, Object?>{'type': 'clear_audio'});
    _preSpeechFrames.clear();
    _preSpeechBytes = 0;
    _log('No voice detected');
    await _pauseListening(status: 'Paused - no voice');
  }

  Future<void> _handlePostVoiceSilenceTimeout() async {
    if (!mounted ||
        !_isConnected ||
        _phase != CallPhase.listening ||
        !_voiceStarted) {
      return;
    }
    final int elapsedSinceVoiceMs =
        DateTime.now().millisecondsSinceEpoch - _lastVoiceAtMs;
    if (elapsedSinceVoiceMs < _postVoiceSilenceTimeout.inMilliseconds - 120) {
      _schedulePostVoiceSilenceTimeout();
      return;
    }
    await _stopListening();
  }

  Future<void> _pauseListening({required String status}) async {
    _cancelListeningTimeout();
    _stopRecordingWatch();
    await _audio.stopRecording();
    await _micSubscription?.cancel();
    _micSubscription = null;
    if (!mounted || !_isConnected) {
      return;
    }
    setState(() {
      _phase = CallPhase.ready;
      _status = status;
      _micLevel = 0;
    });
    _scheduleConnectedIdleTimer();
  }

  void _scheduleConnectedIdleTimer() {
    _connectedIdleTimer?.cancel();
    if (!_isConnected || !_autoListenEnabled || _phase != CallPhase.ready) {
      return;
    }
    _connectedIdleTimer = Timer(_connectedIdleTimeout, () {
      unawaited(_disconnect());
    });
  }

  void _cancelConnectedIdleTimer() {
    _connectedIdleTimer?.cancel();
    _connectedIdleTimer = null;
  }

  void _sendWelcomeIfReady(Map<String, dynamic> event) {
    if (_welcomeSent || !_isConnected) {
      return;
    }
    final String? sessionPersona =
        (event['persona_id'] as String?) ?? (event['persona'] as String?);
    final String targetPersona =
        _callPersonaName ??
        _pendingCallPersonaName ??
        _selectedPersona?.name ??
        sessionPersona ??
        'spark';
    if (sessionPersona != targetPersona) {
      _log(
        'Session persona $sessionPersona did not match call persona '
        '$targetPersona; requesting switch',
      );
      _sendJson(<String, Object?>{
        'type': 'set_persona',
        'persona_id': targetPersona,
      });
      return;
    }
    _welcomeSent = true;
    _sendJson(<String, Object?>{
      'type': 'welcome',
      'persona_id': targetPersona,
      'tts_mode': _ttsMode,
    });
    _log('Welcome requested for $targetPersona');
  }

  void _sendJson(Map<String, Object?> payload) {
    final WebSocket? socket = _socket;
    if (socket == null) {
      return;
    }
    socket.add(jsonEncode(payload));
  }

  void _readAudioConfig(Map<String, dynamic> event) {
    final Map<String, dynamic>? input = (event['input_audio'] as Map?)
        ?.cast<String, dynamic>();
    final Map<String, dynamic>? output = (event['output_audio'] as Map?)
        ?.cast<String, dynamic>();
    _inputSampleRate = _readInt(input?['sample_rate'], fallback: 16000);
    _frameMs = _readInt(input?['frame_ms'], fallback: 20);
    _outputSampleRate = _readInt(output?['sample_rate'], fallback: 24000);
  }

  bool _isConfiguredSessionReady(Map<String, dynamic> event) {
    if (_sessionStartAcknowledged) {
      return true;
    }
    if (!event.containsKey('configured')) {
      return _legacyConfiguredSessionReady(event);
    }
    if (event['configured'] != true) {
      return false;
    }
    final String? sessionPersona =
        (event['persona_id'] as String?) ?? (event['persona'] as String?);
    final String? targetPersona =
        _callPersonaName ?? _pendingCallPersonaName ?? _selectedPersona?.name;
    return targetPersona == null ||
        sessionPersona == null ||
        sessionPersona == targetPersona;
  }

  bool _legacyConfiguredSessionReady(Map<String, dynamic> event) {
    final Map<String, dynamic>? clientTts = (event['client_tts'] as Map?)
        ?.cast<String, dynamic>();
    if (clientTts == null || clientTts.isEmpty) {
      return false;
    }
    final String? sessionPersona =
        (event['persona_id'] as String?) ?? (event['persona'] as String?);
    final String? targetPersona =
        _callPersonaName ?? _pendingCallPersonaName ?? _selectedPersona?.name;
    return targetPersona == null ||
        sessionPersona == null ||
        sessionPersona == targetPersona;
  }

  void _rememberTtsMode(Map<String, dynamic> event) {
    final String? mode = event['tts_mode'] as String?;
    if (mode == null || mode.isEmpty || !mounted) {
      return;
    }
    if (mode != 'client_text') {
      setState(() {
        _metrics['tts_mode_preference'] = _preferredTtsMode;
        _metrics['tts_mode'] = mode;
        _metrics['unsupported_tts_mode'] = true;
      });
      _log('Unsupported tts_mode=$mode; StoryVault requires client_text');
      unawaited(_closeUnsupportedTtsMode(mode));
      return;
    }
    setState(() {
      _ttsMode = mode;
      _metrics['tts_mode_preference'] = _preferredTtsMode;
      _metrics['tts_mode'] = mode;
      if (event['tts_engine'] != null) {
        _metrics['server_tts_engine'] = event['tts_engine'];
      }
      if (event['tts_voice'] != null) {
        _metrics['server_tts_voice'] = event['tts_voice'];
      }
      final Object? personaId = event['persona_id'] ?? event['persona'];
      if (personaId != null) {
        _metrics['session_persona'] = personaId;
      }
    });
  }

  Future<void> _closeUnsupportedTtsMode(String mode) async {
    _autoListenEnabled = false;
    _turnRunning = false;
    _waitingForGeneratedWelcome = false;
    _pendingCallPersonaName = null;
    _callPersonaName = null;
    await _stopListening(sendAudioEnd: false);
    await _localPocketTts.stop(resetWorker: true);
    await _audio.stopPlayback();
    final WebSocket? socket = _socket;
    _socket = null;
    final bool wasDisconnecting = _disconnecting;
    _disconnecting = true;
    await socket?.close(
      WebSocketStatus.unsupportedData,
      'client_text_tts_required',
    );
    _disconnecting = wasDisconnecting;
    if (!mounted) {
      return;
    }
    setState(() {
      _phase = CallPhase.disconnected;
      _status = 'Voice server must send text';
      _metrics['unsupported_tts_mode'] = mode;
    });
  }

  void _rememberAsrAudio(Map<String, dynamic> event) {
    final Object? durationMs = event['audio_duration_ms'];
    final Object? bytes = event['audio_bytes'];
    final Object? chunks = event['audio_chunks'];
    if (!mounted) {
      return;
    }
    setState(() {
      if (durationMs != null) {
        _metrics['asr_audio_ms'] = durationMs;
      }
      if (bytes != null) {
        _metrics['asr_audio_bytes'] = bytes;
      }
      if (chunks != null) {
        _metrics['asr_audio_chunks'] = chunks;
      }
    });
  }

  void _rememberTokenUsage(Map<String, dynamic> event) {
    final Map<String, dynamic>? turn = (event['turn'] as Map?)
        ?.cast<String, dynamic>();
    final Map<String, dynamic>? session = (event['session'] as Map?)
        ?.cast<String, dynamic>();
    if (!mounted) {
      return;
    }
    setState(() {
      if (turn != null) {
        _metrics['llm_prompt_tokens'] = turn['prompt_tokens'];
        _metrics['llm_completion_tokens'] = turn['completion_tokens'];
        _metrics['llm_total_tokens'] = turn['total_tokens'];
        _metrics['llm_token_usage_source'] = turn['source'];
        _metrics['llm_token_usage_estimated'] = turn['estimated'];
      }
      if (session != null) {
        _metrics['session_llm_prompt_tokens'] = session['prompt_tokens'];
        _metrics['session_llm_completion_tokens'] =
            session['completion_tokens'];
        _metrics['session_llm_total_tokens'] = session['total_tokens'];
        _metrics['session_llm_token_usage_source'] = session['source'];
        _metrics['session_llm_token_usage_estimated'] = session['estimated'];
      }
      _metrics['session_turns'] = event['session_turns'];
    });
  }

  bool get _isNoiseCalibrating {
    if (_voiceStarted || _listenStartedAtMs == 0) {
      return false;
    }
    final int elapsedMs =
        DateTime.now().millisecondsSinceEpoch - _listenStartedAtMs;
    return elapsedMs < _noiseCalibrationWindow.inMilliseconds;
  }

  double get _adaptiveVoiceRmsThreshold {
    if (_noiseFloorFrames == 0) {
      return _voiceRmsThreshold;
    }
    return math.max(
      _voiceRmsThreshold,
      (_noiseRmsFloor * _voiceNoiseRmsMultiplier) + _voiceNoiseRmsMargin,
    );
  }

  void _seedNoiseFloor(_MicFrameStats stats) {
    if (_noiseFloorFrames > 0) {
      return;
    }
    _noiseRmsFloor = stats.rms;
    _noisePeakFloor = stats.peak;
    _noiseFloorFrames = 1;
  }

  void _updateNoiseFloor(_MicFrameStats stats, {required bool acceptedVoice}) {
    if (_noiseFloorFrames == 0) {
      _seedNoiseFloor(stats);
      return;
    }
    if (_voiceStarted && acceptedVoice) {
      return;
    }

    final double riseAlpha = acceptedVoice ? 0.002 : _noiseFloorRiseAlpha;
    _noiseRmsFloor = _smoothNoiseFloor(
      floor: _noiseRmsFloor,
      observed: stats.rms,
      riseAlpha: riseAlpha,
    );
    _noisePeakFloor = _smoothNoiseFloor(
      floor: _noisePeakFloor,
      observed: stats.peak,
      riseAlpha: riseAlpha,
    );
    _noiseFloorFrames += 1;
  }

  double _smoothNoiseFloor({
    required double floor,
    required double observed,
    required double riseAlpha,
  }) {
    if (floor <= 0) {
      return observed;
    }
    final double alpha = observed < floor ? _noiseFloorFallAlpha : riseAlpha;
    return (floor * (1 - alpha)) + (observed * alpha);
  }

  bool _isHumanVoiceFrame({
    required bool nativeSpeech,
    required _MicFrameStats stats,
  }) {
    if (_isNoiseCalibrating || !nativeSpeech) {
      return false;
    }
    final bool speechLikeFrequency =
        stats.zeroCrossingRate >= _voiceMinZeroCrossingRate &&
        stats.zeroCrossingRate <= _voiceMaxZeroCrossingRate;
    return speechLikeFrequency &&
        stats.peak >= _voicePeakThreshold &&
        stats.rms >= _adaptiveVoiceRmsThreshold;
  }

  void _startRecordingWatch() {
    _recordingWatchTimer?.cancel();
    _recordingWatchTimer = Timer.periodic(
      const Duration(milliseconds: 500),
      (_) => unawaited(_refreshRecordingStatus()),
    );
    unawaited(_refreshRecordingStatus());
  }

  void _stopRecordingWatch() {
    _recordingWatchTimer?.cancel();
    _recordingWatchTimer = null;
  }

  Future<void> _refreshRecordingStatus() async {
    Map<String, dynamic> status;
    try {
      status = await _audio.recordingStatus();
    } catch (error) {
      _log('Mic status failed: $error');
      return;
    }
    if (!mounted) {
      return;
    }

    final int nativeBytes = _readInt(status['bytesRead'], fallback: 0);
    final int nativeFrames = _readInt(status['framesRead'], fallback: 0);
    final int readErrors = _readInt(status['readErrors'], fallback: 0);
    final String source = (status['audioSource'] as String?) ?? '';
    final String vadSource = (status['vadSource'] as String?) ?? '';
    final String vadMode = (status['vadMode'] as String?) ?? '';
    final int vadSpeechFrames = _readInt(
      status['vadSpeechFrames'],
      fallback: 0,
    );
    final int vadNoiseFrames = _readInt(status['vadNoiseFrames'], fallback: 0);
    final int vadErrors = _readInt(status['vadErrors'], fallback: 0);
    final bool hasSink = status['hasEventSink'] == true;
    final bool recording = status['recording'] == true;
    final int elapsedMs =
        DateTime.now().millisecondsSinceEpoch - _listenStartedAtMs;
    final int clientUtteranceBytes = _micBytes - _listenStartMicBytes;

    setState(() {
      _nativeMicBytes = nativeBytes;
      _nativeMicFrames = nativeFrames;
      _nativeAudioSource = source;
      _nativeVadSource = vadSource;
      _nativeVadMode = vadMode;
      _metrics['native_mic_bytes'] = nativeBytes;
      _metrics['native_mic_frames'] = nativeFrames;
      _metrics['native_mic_source'] = source;
      _metrics['native_mic_sink'] = hasSink;
      if (vadSource.isNotEmpty) {
        _metrics['native_vad_source'] = vadSource;
      }
      if (vadMode.isNotEmpty) {
        _metrics['native_vad_mode'] = vadMode;
      }
      if (_noiseFloorFrames > 0) {
        _metrics['noise_rms_floor'] = _noiseRmsFloor.toStringAsFixed(4);
        _metrics['voice_rms_gate'] = _adaptiveVoiceRmsThreshold.toStringAsFixed(
          4,
        );
      }
      _metrics['native_vad_speech_frames'] = vadSpeechFrames;
      _metrics['native_vad_noise_frames'] = vadNoiseFrames;
      if (readErrors > 0) {
        _metrics['native_mic_read_errors'] = readErrors;
      }
      if (vadErrors > 0) {
        _metrics['native_vad_errors'] = vadErrors;
      }
      if (_phase == CallPhase.listening) {
        if (!recording) {
          _status = 'Listening - recorder stopped';
        } else if (!hasSink) {
          _status = 'Listening - waiting for mic stream';
        } else if (elapsedMs > 1000 && nativeBytes == 0) {
          _status = 'Listening - no native mic frames';
        } else if (_isNoiseCalibrating) {
          _status = 'Listening - sampling room';
        } else if (!_voiceStarted) {
          _status = 'Listening - waiting for voice';
        } else if (nativeBytes > 0 && clientUtteranceBytes == 0) {
          _status = 'Listening - event bridge quiet';
        }
        _micLevel *= 0.86;
      }
    });
  }

  _MicFrameStats _analyzeMicFrame(Uint8List frame) {
    if (frame.length < 2) {
      return const _MicFrameStats(
        level: 0,
        isHumanVoice: false,
        rms: 0,
        peak: 0,
        zeroCrossingRate: 0,
      );
    }
    final ByteData data = ByteData.sublistView(frame);
    double sumSquares = 0;
    double peak = 0;
    int samples = 0;
    int zeroCrossings = 0;
    int previousSign = 0;
    for (int offset = 0; offset + 1 < frame.length; offset += 2) {
      final double sample = data.getInt16(offset, Endian.little) / 32768.0;
      final double absolute = sample.abs();
      sumSquares += sample * sample;
      if (absolute > peak) {
        peak = absolute;
      }
      final int sign = sample > 0
          ? 1
          : sample < 0
          ? -1
          : 0;
      if (sign != 0 && previousSign != 0 && sign != previousSign) {
        zeroCrossings += 1;
      }
      if (sign != 0) {
        previousSign = sign;
      }
      samples += 1;
    }
    if (samples == 0) {
      return const _MicFrameStats(
        level: 0,
        isHumanVoice: false,
        rms: 0,
        peak: 0,
        zeroCrossingRate: 0,
      );
    }
    final double rms = math.sqrt(sumSquares / samples);
    final double zcr = zeroCrossings / samples;
    final bool isHumanVoice =
        rms >= _voiceRmsThreshold &&
        peak >= _voicePeakThreshold &&
        zcr >= _voiceMinZeroCrossingRate &&
        zcr <= _voiceMaxZeroCrossingRate;
    return _MicFrameStats(
      level: math.min(1.0, rms * 8.0),
      isHumanVoice: isHumanVoice,
      rms: rms,
      peak: peak,
      zeroCrossingRate: zcr,
    );
  }

  void _replacePersonasFromSession(Map<String, dynamic> event) {
    final List<dynamic>? rawPersonas =
        event['available_personas'] as List<dynamic>?;
    if (rawPersonas == null) {
      return;
    }
    final List<PersonaProfile> personas = rawPersonas
        .whereType<Map<String, dynamic>>()
        .map(PersonaProfile.fromJson)
        .toList();
    if (personas.isEmpty) {
      return;
    }
    _personas = personas.map((PersonaProfile persona) {
      final PersonaProfile? existing = _firstWhereOrNull(
        _personas,
        (PersonaProfile item) => item.name == persona.name,
      );
      return existing == null
          ? persona
          : persona.copyWith(
              cachedThumbnailPath: existing.cachedThumbnailPath,
              cachedPortraitPath: existing.cachedPortraitPath,
              cachedVoiceSamplePath:
                  existing.voiceCacheKey == persona.voiceCacheKey
                  ? existing.cachedVoiceSamplePath
                  : null,
            );
    }).toList();
    final String activeName =
        (event['persona_id'] as String?) ??
        (event['persona'] as String?) ??
        personas.first.name;
    final String desiredName =
        _callPersonaName ?? _pendingCallPersonaName ?? activeName;
    _selectedPersona = _firstWhereOrNull(
      _personas,
      (PersonaProfile persona) => persona.name == desiredName,
    );
    _selectedPersona ??= _firstWhereOrNull(
      _personas,
      (PersonaProfile persona) => persona.name == activeName,
    );
    _selectedPersona ??= _personas.first;
  }

  void _handleSocketDone() {
    _stopRecordingWatch();
    _cancelAssistantPlaybackTimer();
    _autoListenEnabled = false;
    if (_disconnecting || !mounted) {
      return;
    }
    setState(() {
      _socket = null;
      _phase = CallPhase.disconnected;
      _status = 'Disconnected';
      _turnRunning = false;
      _waitingForGeneratedWelcome = false;
      _pendingCallPersonaName = null;
      _callPersonaName = null;
    });
    _log('WebSocket closed');
  }

  void _handleSocketError(Object error) {
    _stopRecordingWatch();
    _cancelAssistantPlaybackTimer();
    _autoListenEnabled = false;
    _log('WebSocket error: $error');
    if (!mounted) {
      return;
    }
    setState(() {
      _socket = null;
      _phase = CallPhase.disconnected;
      _status = 'Socket error';
      _turnRunning = false;
      _waitingForGeneratedWelcome = false;
      _pendingCallPersonaName = null;
      _callPersonaName = null;
    });
  }

  void _setLastUserText(String text) {
    if (!mounted) {
      return;
    }
    setState(() {
      _lastUserText = text;
    });
    _scrollTranscriptSoon();
  }

  void _setPhase(CallPhase phase, String status) {
    if (!mounted) {
      return;
    }
    setState(() {
      _phase = phase;
      _status = status;
    });
  }

  void _setStatus(String status) {
    if (!mounted) {
      return;
    }
    setState(() {
      _status = status;
    });
  }

  void _setLiveAudioCaption(String caption) {
    if (_liveAudioCaption == caption) {
      return;
    }
    if (!mounted) {
      _liveAudioCaption = caption;
      return;
    }
    setState(() {
      _liveAudioCaption = caption;
    });
  }

  void _log(String value) {
    if (!_diagnosticsEnabled) {
      return;
    }
    final DateTime now = DateTime.now();
    final String stamp =
        '${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}:${now.second.toString().padLeft(2, '0')}';
    // Keep a stdout copy for attached device debugging.
    // ignore: avoid_print
    print('StoryVaultTalk $stamp $value');
    if (!mounted) {
      return;
    }
    setState(() {
      _events.insert(0, '$stamp $value');
      if (_events.length > 80) {
        _events.removeLast();
      }
    });
  }

  void _logTtsText(String label, String text) {
    if (!_diagnosticsEnabled) {
      return;
    }
    final String normalized = text.trim();
    final String hash = _stableTextHash(normalized);
    final String preview = _previewLogText(normalized);
    _log('$label chars=${normalized.length} textHash=$hash "$preview"');
    developer.log(
      '$label chars=${normalized.length} textHash=$hash text="$normalized"',
      name: 'StoryVaultTalk',
    );
  }

  void _recordQueuedPocketTtsChunk(
    _LocalTtsChunk chunk, {
    required int generation,
    required String reason,
  }) {
    if (!_diagnosticsEnabled) {
      return;
    }
    final String line = _formatTextChunkLogLine(
      id: chunk.id,
      label: 'POCKET_TTS_QUEUE/$reason',
      text: chunk.text,
    );
    _pocketTtsQueuedChunkLog = _appendBoundedTextLog(
      _pocketTtsQueuedChunkLog,
      line,
    );
    _pocketTtsFullQueuedInput = _appendTextWithSpace(
      _pocketTtsFullQueuedInput,
      chunk.text,
    );
    _writeTalkTextLog('gen=$generation $line');
    if (!mounted) {
      return;
    }
    setState(() {
      _metrics['pocket_tts_queued_chunks'] = _pocketTtsQueuedChunkLog;
      _metrics['pocket_tts_full_queued_input'] = _pocketTtsFullQueuedInput;
    });
  }

  void _recordSpokenPocketTtsChunk(_LocalTtsChunk chunk, int generation) {
    if (!_diagnosticsEnabled) {
      return;
    }
    final String line = _formatTextChunkLogLine(
      id: chunk.id,
      label: 'POCKET_TTS_SPEAK',
      text: chunk.text,
    );
    _pocketTtsSpokenChunkLog = _appendBoundedTextLog(
      _pocketTtsSpokenChunkLog,
      line,
    );
    _pocketTtsFullSpokenInput = _appendTextWithSpace(
      _pocketTtsFullSpokenInput,
      chunk.text,
    );
    _writeTalkTextLog('gen=$generation $line');
    if (!mounted) {
      return;
    }
    setState(() {
      _metrics['pocket_tts_spoken_chunks'] = _pocketTtsSpokenChunkLog;
      _metrics['pocket_tts_full_spoken_input'] = _pocketTtsFullSpokenInput;
    });
  }

  String _formatTextChunkLogLine({
    required int id,
    required String label,
    required String text,
  }) {
    final String normalized = text.replaceAll(RegExp(r'\s+'), ' ').trim();
    return '$label #$id chars=${normalized.length} '
        'hash=${_stableTextHash(normalized)} text="$normalized"';
  }

  String _appendBoundedTextLog(String existing, String line) {
    final String next = existing.isEmpty ? line : '$existing\n$line';
    if (next.length <= _diagnosticChunkLogMaxChars) {
      return next;
    }
    return '[trimmed]\n${next.substring(next.length - _diagnosticChunkLogMaxChars)}';
  }

  String _appendTextWithSpace(String existing, String text) {
    final String normalized = text.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (normalized.isEmpty) {
      return existing;
    }
    final String next = existing.isEmpty ? normalized : '$existing $normalized';
    return _trimDiagnosticTail(next, limit: _diagnosticFullTextMaxChars);
  }

  String _trimDiagnosticTail(String text, {required int limit}) {
    if (text.length <= limit) {
      return text;
    }
    final String tail = text.substring(text.length - limit);
    return '[trimmed ${text.length - limit} chars]\n$tail';
  }

  void _writeTalkTextLog(String value) {
    if (!_diagnosticsEnabled) {
      return;
    }
    final DateTime now = DateTime.now();
    final String line = '${now.toIso8601String()} $value';
    final String consoleLine = line.length <= _diagnosticSheetTextMaxChars
        ? line
        : '${line.substring(0, 320)}\n'
              '[trimmed ${line.length - 640} chars from console log]\n'
              '${line.substring(line.length - 320)}';
    // Keep a stdout copy for attached device debugging.
    // ignore: avoid_print
    print('StoryVaultTalkText $consoleLine');
    developer.log(consoleLine, name: 'StoryVaultTalkText');
    unawaited(_appendTalkTextLogFile('$line\n'));
  }

  Future<void> _appendTalkTextLogFile(String text) async {
    try {
      final Directory directory = await getApplicationDocumentsDirectory();
      final File file = File('${directory.path}/storyvault_talk_text.log');
      _talkTextLogPath ??= file.path;
      await file.writeAsString(text, mode: FileMode.append, flush: true);
      if (mounted && _metrics['talk_text_log_path'] != file.path) {
        setState(() {
          _metrics['talk_text_log_path'] = file.path;
        });
      }
    } catch (error) {
      _log('Talk text file log failed: $error');
    }
  }

  String _previewLogText(String text, {int limit = 140}) {
    final String normalized = text.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (normalized.length <= limit) {
      return normalized;
    }
    return '${normalized.substring(0, math.max(0, limit - 3))}...';
  }

  String _stableTextHash(String text) {
    var hash = 0x811c9dc5;
    for (final int codeUnit in text.codeUnits) {
      hash ^= codeUnit;
      hash = (hash * 0x01000193) & 0xffffffff;
    }
    return hash.toRadixString(16).padLeft(8, '0');
  }

  void _scrollTranscriptSoon() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_transcriptScrollController.hasClients) {
        return;
      }
      _transcriptScrollController.animateTo(
        _transcriptScrollController.position.maxScrollExtent,
        duration: const Duration(milliseconds: 180),
        curve: Curves.easeOut,
      );
    });
  }

  Uri? _baseUri() {
    String raw = _serverController.text.trim();
    if (raw.isEmpty) {
      return null;
    }
    if (!raw.contains('://')) {
      raw = 'http://$raw';
    }
    final Uri? uri = Uri.tryParse(raw);
    if (uri == null || uri.host.isEmpty) {
      return null;
    }
    return uri.path.isEmpty ? uri.replace(path: '/') : uri;
  }

  Uri? _webSocketUri() {
    final Uri? base = _baseUri();
    if (base == null) {
      return null;
    }
    final Uri wsBase = _backendUri('/ws/session', base)!;
    return wsBase.replace(
      scheme: base.scheme == 'https' ? 'wss' : 'ws',
      query: null,
      fragment: null,
    );
  }

  Uri? _backendUri(String path, [Uri? baseUri]) {
    final Uri? absolute = Uri.tryParse(path);
    if (absolute != null && absolute.hasScheme && absolute.host.isNotEmpty) {
      return absolute;
    }
    final Uri? base = baseUri ?? _baseUri();
    if (base == null) {
      return null;
    }

    final String basePath = _normalizedBasePath(base.path);
    final String suffix = path.startsWith('/') ? path : '/$path';
    final String resolvedPath = basePath.isEmpty ? suffix : '$basePath$suffix';
    return base.replace(path: resolvedPath, query: null, fragment: null);
  }

  String _normalizedBasePath(String path) {
    if (path.isEmpty || path == '/') {
      return '';
    }
    var normalized = path;
    while (normalized.endsWith('/')) {
      normalized = normalized.substring(0, normalized.length - 1);
    }
    return normalized;
  }

  T? _firstWhereOrNull<T>(Iterable<T> items, bool Function(T item) test) {
    for (final T item in items) {
      if (test(item)) {
        return item;
      }
    }
    return null;
  }

  int _readInt(Object? value, {required int fallback}) {
    if (value is int) {
      return value;
    }
    if (value is num) {
      return value.round();
    }
    return fallback;
  }

  Future<void> _openSettings() async {
    final _FadTimingSettings? settings =
        await showModalBottomSheet<_FadTimingSettings>(
          context: context,
          showDragHandle: true,
          isScrollControlled: true,
          backgroundColor: const Color(0xFFFFFBF4),
          builder: (BuildContext context) {
            return _SettingsSheet(
              firstVoiceWaitSeconds: _firstVoiceWaitSeconds,
              endWaitSeconds: _endWaitSeconds,
              loadingPersonas: _loadingPersonas,
              onRefreshPersonas: () => _loadPersonas(),
            );
          },
        );
    if (settings == null || !mounted) {
      return;
    }
    setState(() {
      _firstVoiceWaitSeconds = settings.firstVoiceWaitSeconds;
      _endWaitSeconds = settings.endWaitSeconds;
      _metrics['fad_start_wait_s'] = _formatSeconds(_firstVoiceWaitSeconds);
      _metrics['fad_end_wait_s'] = _formatSeconds(_endWaitSeconds);
    });
    if (_phase == CallPhase.listening) {
      if (_voiceStarted) {
        _schedulePostVoiceSilenceTimeout();
      } else {
        _scheduleFirstVoiceTimeout();
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final Color phaseColor = _phase.color;
    final String assistantVisible = _assistantText.isNotEmpty
        ? _assistantText
        : _assistantDraft;
    final PersonaVisual selectedVisual =
        (_waitingForGeneratedWelcome || _callPersonaName != null)
        ? _callVisual
        : _selectedVisual;

    if (_wizardSessionId != null || _wizardBusy || _wizardGeneratingStory) {
      return _GuidedStoryWizardScreen(
        visual: selectedVisual,
        wizardId: _activeWizardId,
        phase: _phase,
        phaseColor: phaseColor,
        status: _wizardStatus.isNotEmpty ? _wizardStatus : _status,
        intro: _wizardIntro,
        introFinished: _wizardIntroFinished,
        questionsStarted: _wizardQuestionsStarted,
        state: _wizardState,
        storyText: _wizardStoryText,
        generatingStory: _wizardGeneratingStory,
        busy: _wizardBusy,
        liveSubtitleText: _liveSubtitleText,
        liveSubtitleActiveWordIndex: _liveSubtitleActiveWordIndex,
        onIntroReady: _beginWizardQuestions,
        onSkipIntro: _skipWizardIntro,
        onChoiceSelected: _answerWizardChoice,
        onAbort: _endWizardSession,
      );
    }

    if (_waitingForGeneratedWelcome) {
      return _RingingScreen(
        visual: selectedVisual,
        status: _status,
        onCancel: _disconnect,
      );
    }

    if (!_isConnected && _phase == CallPhase.disconnected) {
      return _WizardHomeScreen(
        serverController: _serverController,
        serverEnabled: true,
        visuals: _availableVisuals,
        selectedVisual: selectedVisual,
        onOpenSettings: _openSettings,
        onPersonaSelected: _selectVisualPersona,
      );
    }

    return _CallExperienceScreen(
      visual: selectedVisual,
      phase: _phase,
      phaseColor: phaseColor,
      status: _status,
      micLevel: _micLevel,
      eventCount: _eventCount,
      micBytes: _micBytes,
      micFrames: _micFramesSent,
      nativeMicBytes: _nativeMicBytes,
      nativeMicFrames: _nativeMicFrames,
      nativeAudioSource: _nativeAudioSource,
      nativeVadSource: _nativeVadSource,
      nativeVadMode: _nativeVadMode,
      audioBytes: _audioBytes,
      transcriptController: _transcriptScrollController,
      userText: _lastUserText,
      assistantText: assistantVisible,
      liveAudioCaption: _liveAudioCaption,
      liveSubtitleText: _liveSubtitleText,
      liveSubtitleActiveWordIndex: _liveSubtitleActiveWordIndex,
      metrics: _metrics,
      events: _events,
      textController: _textController,
      textEnabled: _phase != CallPhase.connecting,
      canStopAudio: _turnRunning || _phase == CallPhase.speaking,
      onMainButtonTap: _handleMainButtonTap,
      onStopAudio: _stopAudioAndListen,
      onEndCall: _disconnect,
      onSendText: _sendTextTurn,
      onTestAudio: _playDiagnosticTone,
    );
  }
}

class _WizardHomeScreen extends StatelessWidget {
  const _WizardHomeScreen({
    required this.serverController,
    required this.serverEnabled,
    required this.visuals,
    required this.selectedVisual,
    required this.onOpenSettings,
    required this.onPersonaSelected,
  });

  final TextEditingController serverController;
  final bool serverEnabled;
  final List<PersonaVisual> visuals;
  final PersonaVisual selectedVisual;
  final VoidCallback onOpenSettings;
  final ValueChanged<PersonaVisual> onPersonaSelected;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Stack(
        children: <Widget>[
          const Positioned.fill(
            child: Image(
              image: AssetImage(_appBackgroundAsset),
              fit: BoxFit.cover,
            ),
          ),
          Positioned.fill(
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: <Color>[
                    Colors.white.withValues(alpha: 0.06),
                    const Color(0xFF311B72).withValues(alpha: 0.10),
                    const Color(0xFF2A174B).withValues(alpha: 0.24),
                  ],
                ),
              ),
            ),
          ),
          SafeArea(
            bottom: false,
            child: Column(
              children: <Widget>[
                Padding(
                  padding: const EdgeInsets.fromLTRB(18, 12, 18, 4),
                  child: Row(
                    children: <Widget>[
                      _RoundGlyphButton(
                        icon: Icons.arrow_back_rounded,
                        color: const Color(0xFFE0A82E),
                        onTap: () => Navigator.of(context).maybePop(),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Text(
                          'Hello',
                          textAlign: TextAlign.center,
                          style: Theme.of(context).textTheme.headlineSmall
                              ?.copyWith(
                                color: const Color(0xFF30233B),
                                fontWeight: FontWeight.w900,
                              ),
                        ),
                      ),
                      _RoundGlyphButton(
                        icon: Icons.settings_rounded,
                        color: const Color(0xFF50366F),
                        onTap: onOpenSettings,
                      ),
                    ],
                  ),
                ),
                Text(
                  'Who will tell your story today?',
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    color: const Color(0xFF493458),
                    fontWeight: FontWeight.w700,
                  ),
                  textAlign: TextAlign.center,
                ),
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(14, 14, 14, 4),
                    child: _PersonaTileGrid(
                      visuals: visuals,
                      selectedVisual: selectedVisual,
                      onPersonaSelected: onPersonaSelected,
                    ),
                  ),
                ),
                if (_diagnosticsEnabled)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(14, 8, 14, 10),
                    child: _ConnectionSettings(
                      controller: serverController,
                      enabled: serverEnabled,
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ignore: unused_element
class _PersonaWheel extends StatefulWidget {
  const _PersonaWheel({
    required this.visuals,
    required this.selectedVisual,
    required this.onPersonaSelected,
  });

  final List<PersonaVisual> visuals;
  final PersonaVisual selectedVisual;
  final ValueChanged<PersonaVisual> onPersonaSelected;

  @override
  State<_PersonaWheel> createState() => _PersonaWheelState();
}

class _PersonaWheelState extends State<_PersonaWheel>
    with SingleTickerProviderStateMixin {
  static const double _topAngle = -math.pi / 2;

  late final AnimationController _controller;
  late Animation<double> _animation;
  double _angle = 0;
  bool _isSpinning = false;

  @override
  void initState() {
    super.initState();
    _angle = _targetAngleForIndex(
      _selectedIndex(widget.visuals),
      math.max(1, widget.visuals.length),
    );
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2800),
    );
    _animation = AlwaysStoppedAnimation<double>(_angle);
  }

  @override
  void didUpdateWidget(covariant _PersonaWheel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (_isSpinning || oldWidget.visuals.length == widget.visuals.length) {
      return;
    }
    _angle = _targetAngleForIndex(
      _selectedIndex(widget.visuals),
      math.max(1, widget.visuals.length),
    );
    _animation = AlwaysStoppedAnimation<double>(_angle);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _spin() {
    if (_isSpinning || widget.visuals.isEmpty) {
      return;
    }
    final int target = math.Random().nextInt(widget.visuals.length);
    _animateToIndex(
      target,
      extraTurns: 4,
      duration: const Duration(milliseconds: 2800),
      curve: Curves.decelerate,
      shortestPath: false,
    );
  }

  void _selectByTap(int index) {
    if (_isSpinning || widget.visuals.isEmpty) {
      return;
    }
    HapticFeedback.selectionClick();
    widget.onPersonaSelected(widget.visuals[index]);
    _animateToIndex(
      index,
      extraTurns: 0,
      duration: const Duration(milliseconds: 620),
      curve: Curves.easeOutCubic,
      shortestPath: true,
      notifyOnComplete: false,
    );
  }

  void _animateToIndex(
    int target, {
    required int extraTurns,
    required Duration duration,
    required Curve curve,
    required bool shortestPath,
    bool notifyOnComplete = true,
  }) {
    final int count = math.max(1, widget.visuals.length);
    final double targetAngle = _targetAngleForIndex(target, count);
    final double current = _normalizeAngle(_angle);
    final double targetNormalized = _normalizeAngle(targetAngle);
    final double delta = shortestPath
        ? _shortestDelta(current, targetNormalized)
        : _normalizeAngle(targetNormalized - current);
    final double end = _angle + (2 * math.pi * extraTurns) + delta;
    _controller.duration = duration;
    _animation = Tween<double>(
      begin: _angle,
      end: end,
    ).animate(CurvedAnimation(parent: _controller, curve: curve));
    setState(() {
      _isSpinning = true;
    });
    _controller.forward(from: 0).then((_) {
      _angle = end;
      HapticFeedback.heavyImpact();
      if (notifyOnComplete) {
        widget.onPersonaSelected(widget.visuals[target]);
      }
      if (mounted) {
        setState(() {
          _isSpinning = false;
        });
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final double size = math.min(
          constraints.maxWidth,
          constraints.maxHeight,
        );
        return Center(
          child: SizedBox(
            width: size,
            height: size,
            child: AnimatedBuilder(
              animation: _controller,
              builder: (BuildContext context, Widget? child) {
                final double angle = _isSpinning ? _animation.value : _angle;
                return Stack(
                  clipBehavior: Clip.none,
                  alignment: Alignment.center,
                  children: <Widget>[
                    ClipOval(
                      child: SizedBox(
                        width: size,
                        height: size,
                        child: Transform.rotate(
                          angle: angle,
                          child: Image.asset(
                            'assets/images/wheel.png',
                            width: size,
                            height: size,
                            fit: BoxFit.contain,
                          ),
                        ),
                      ),
                    ),
                    Positioned(
                      top: -size * 0.05,
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          color: const Color(0xFFF7C948),
                          shape: BoxShape.circle,
                          boxShadow: <BoxShadow>[
                            BoxShadow(
                              color: const Color(
                                0xFFF7C948,
                              ).withValues(alpha: 0.45),
                              blurRadius: 12,
                              spreadRadius: 1,
                            ),
                          ],
                        ),
                        child: const SizedBox(
                          width: 26,
                          height: 26,
                          child: Icon(
                            Icons.star_rounded,
                            color: Color(0xFF8B6000),
                            size: 16,
                          ),
                        ),
                      ),
                    ),
                    ...List<Widget>.generate(widget.visuals.length, (int i) {
                      return _buildAvatar(i, size, angle);
                    }),
                    ...List<Widget>.generate(widget.visuals.length, (int i) {
                      return _buildTapZone(i, size, angle);
                    }),
                    _SpinDisc(
                      size: size * 0.22,
                      spinning: _isSpinning,
                      onTap: _spin,
                    ),
                  ],
                );
              },
            ),
          ),
        );
      },
    );
  }

  Widget _buildAvatar(int index, double size, double wheelAngle) {
    final PersonaVisual visual = widget.visuals[index];
    final _WheelPosition position = _positionFor(index, size, wheelAngle);
    final bool selected = visual.id == widget.selectedVisual.id;
    final double avatarSize = position.avatarSize;

    return Positioned(
      left: size / 2 + position.dx - avatarSize / 2,
      top: size / 2 + position.dy - avatarSize / 2,
      width: avatarSize,
      height: avatarSize,
      child: AnimatedScale(
        scale: selected ? 1.06 : 1,
        duration: const Duration(milliseconds: 180),
        child: _WheelPersonaSprite(
          visual: visual,
          selected: selected,
          size: avatarSize,
        ),
      ),
    );
  }

  Widget _buildTapZone(int index, double size, double wheelAngle) {
    final _WheelPosition position = _positionFor(index, size, wheelAngle);
    final double tapSize = position.avatarSize * 1.08;
    return Positioned(
      left: size / 2 + position.dx - tapSize / 2,
      top: size / 2 + position.dy - tapSize / 2,
      width: tapSize,
      height: tapSize,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: _isSpinning ? null : () => _selectByTap(index),
      ),
    );
  }

  _WheelPosition _positionFor(int index, double size, double wheelAngle) {
    final int count = math.max(1, widget.visuals.length);
    final double baseAngle = _segmentMidpoint(index, count);
    final double screenAngle = count == 1 ? _topAngle : baseAngle + wheelAngle;
    final double radius = size * 0.305;
    return _WheelPosition(
      dx: math.cos(screenAngle) * radius,
      dy: math.sin(screenAngle) * radius,
      avatarSize: size * 0.195,
    );
  }

  int _selectedIndex(List<PersonaVisual> visuals) {
    final int selected = visuals.indexWhere(
      (PersonaVisual visual) => visual.id == widget.selectedVisual.id,
    );
    return selected < 0 ? 0 : selected;
  }

  double _segmentMidpoint(int index, int count) {
    if (count <= 1) {
      return _topAngle;
    }
    final double segmentAngle = (2 * math.pi) / count;
    return _topAngle + (index * segmentAngle) + (segmentAngle / 2);
  }

  double _targetAngleForIndex(int index, int count) {
    return _topAngle - _segmentMidpoint(index, count);
  }

  double _normalizeAngle(double angle) {
    final double normalized = angle % (2 * math.pi);
    return normalized < 0 ? normalized + (2 * math.pi) : normalized;
  }

  double _shortestDelta(double current, double target) {
    double delta = target - current;
    if (delta > math.pi) {
      delta -= 2 * math.pi;
    } else if (delta < -math.pi) {
      delta += 2 * math.pi;
    }
    return delta;
  }
}

// ignore: unused_element
class _WheelPosition {
  const _WheelPosition({
    required this.dx,
    required this.dy,
    required this.avatarSize,
  });

  final double dx;
  final double dy;
  final double avatarSize;
}

// ignore: unused_element
class _SpinDisc extends StatelessWidget {
  const _SpinDisc({
    required this.size,
    required this.spinning,
    required this.onTap,
  });

  final double size;
  final bool spinning;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: spinning ? null : onTap,
      child: AnimatedScale(
        scale: spinning ? 0.94 : 1,
        duration: const Duration(milliseconds: 140),
        child: Container(
          width: size,
          height: size,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            gradient: const LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: <Color>[Color(0xFFFFD35A), Color(0xFFE08A18)],
            ),
            boxShadow: <BoxShadow>[
              BoxShadow(
                color: const Color(0xFFE08A18).withValues(alpha: 0.45),
                blurRadius: 14,
                offset: const Offset(0, 6),
              ),
            ],
          ),
          child: Icon(
            spinning ? Icons.sync_rounded : Icons.autorenew_rounded,
            color: const Color(0xFF6D4300),
            size: size * 0.46,
          ),
        ),
      ),
    );
  }
}

class _PersonaTileGrid extends StatelessWidget {
  const _PersonaTileGrid({
    required this.visuals,
    required this.selectedVisual,
    required this.onPersonaSelected,
  });

  final List<PersonaVisual> visuals;
  final PersonaVisual selectedVisual;
  final ValueChanged<PersonaVisual> onPersonaSelected;

  @override
  Widget build(BuildContext context) {
    if (visuals.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }
    return GridView.builder(
      padding: EdgeInsets.zero,
      itemCount: visuals.length,
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 3,
        crossAxisSpacing: 10,
        mainAxisSpacing: 10,
        childAspectRatio: 0.64,
      ),
      itemBuilder: (BuildContext context, int index) {
        final PersonaVisual visual = visuals[index];
        return _PersonaTile(
          visual: visual,
          selected: visual.id == selectedVisual.id,
          onTap: () => onPersonaSelected(visual),
        );
      },
    );
  }
}

class _PersonaTile extends StatelessWidget {
  const _PersonaTile({
    required this.visual,
    required this.selected,
    required this.onTap,
  });

  final PersonaVisual visual;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final Color borderColor = selected
        ? const Color(0xFFF7C948)
        : Colors.white.withValues(alpha: 0.76);
    return Material(
      color: Colors.transparent,
      borderRadius: BorderRadius.circular(8),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 160),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: borderColor, width: selected ? 3 : 1.5),
            boxShadow: <BoxShadow>[
              if (selected)
                BoxShadow(
                  color: visual.color.withValues(alpha: 0.28),
                  blurRadius: 14,
                  offset: const Offset(0, 7),
                ),
            ],
          ),
          child: Stack(
            fit: StackFit.expand,
            children: <Widget>[
              Positioned.fill(
                child: Image(
                  image: visual.imageProvider(portrait: true),
                  fit: BoxFit.cover,
                  alignment: Alignment.center,
                  filterQuality: FilterQuality.high,
                  errorBuilder:
                      (
                        BuildContext context,
                        Object error,
                        StackTrace? stackTrace,
                      ) => Image.asset(
                        visual.assetPath,
                        fit: BoxFit.cover,
                        alignment: Alignment.center,
                      ),
                ),
              ),
              Positioned.fill(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: <Color>[
                        Colors.white.withValues(alpha: selected ? 0.08 : 0.0),
                        Colors.transparent,
                        Colors.black.withValues(alpha: selected ? 0.10 : 0.0),
                      ],
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ignore: unused_element
class _PersonaInfoCard extends StatelessWidget {
  const _PersonaInfoCard({required this.visual});

  final PersonaVisual visual;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 18),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.88),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(
          color: const Color(0xFFF7C948).withValues(alpha: 0.72),
          width: 2,
        ),
        boxShadow: <BoxShadow>[
          BoxShadow(
            color: visual.color.withValues(alpha: 0.18),
            blurRadius: 18,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: Row(
        children: <Widget>[
          SizedBox(
            width: 58,
            height: 58,
            child: _PersonaAvatar(visual: visual, selected: true, padding: 2),
          ),
          const SizedBox(width: 13),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Text(
                  visual.fullName,
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    color: const Color(0xFF2C2434),
                    fontWeight: FontWeight.w900,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  visual.tagline,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: const Color(0xFF65596E),
                    fontWeight: FontWeight.w600,
                    height: 1.25,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _RingingScreen extends StatelessWidget {
  const _RingingScreen({
    required this.visual,
    required this.status,
    required this.onCancel,
  });

  final PersonaVisual visual;
  final String status;
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) {
    final String displayStatus = status.isEmpty
        ? 'Dialing ${visual.fullName}'
        : status;
    final Size screenSize = MediaQuery.sizeOf(context);
    final double figureWidth = math.min(screenSize.width * 0.76, 282);
    final double figureHeight = figureWidth / _personaPortraitAspectRatio;
    const BorderRadius figureRadius = BorderRadius.all(Radius.circular(20));

    return Scaffold(
      body: Stack(
        children: <Widget>[
          const Positioned.fill(
            child: Image(
              image: AssetImage(_appBackgroundAsset),
              fit: BoxFit.cover,
            ),
          ),
          Positioned.fill(
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: <Color>[
                    Colors.white.withValues(alpha: 0.10),
                    visual.color.withValues(alpha: 0.12),
                    const Color(0xFF211636).withValues(alpha: 0.30),
                  ],
                ),
              ),
            ),
          ),
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(22, 18, 22, 24),
              child: Column(
                children: <Widget>[
                  Text(
                    'Calling',
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      color: const Color(0xFF4D365C),
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    visual.fullName,
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                      color: const Color(0xFF2C2434),
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                  Expanded(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.start,
                      children: <Widget>[
                        const Spacer(flex: 1),
                        Container(
                          width: figureWidth,
                          height: figureHeight,
                          decoration: BoxDecoration(
                            borderRadius: figureRadius,
                            color: const Color(
                              0xFFFFF6D8,
                            ).withValues(alpha: 0.90),
                            border: Border.all(
                              color: const Color(
                                0xFFF7C948,
                              ).withValues(alpha: 0.86),
                              width: 5,
                            ),
                            boxShadow: <BoxShadow>[
                              BoxShadow(
                                color: visual.color.withValues(alpha: 0.30),
                                blurRadius: 30,
                                offset: const Offset(0, 16),
                              ),
                            ],
                          ),
                          clipBehavior: Clip.antiAlias,
                          child: ClipRRect(
                            borderRadius: figureRadius,
                            child: Padding(
                              padding: const EdgeInsets.all(5),
                              child: Image(
                                image: visual.imageProvider(portrait: true),
                                fit: BoxFit.cover,
                                alignment: Alignment.center,
                                errorBuilder:
                                    (
                                      BuildContext context,
                                      Object error,
                                      StackTrace? stackTrace,
                                    ) => Image.asset(
                                      visual.assetPath,
                                      fit: BoxFit.cover,
                                      alignment: Alignment.center,
                                    ),
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(height: 22),
                        _RingingPhone(color: visual.color),
                        const SizedBox(height: 14),
                        Text(
                          displayStatus,
                          textAlign: TextAlign.center,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.titleMedium
                              ?.copyWith(
                                color: const Color(0xFF2C2434),
                                fontWeight: FontWeight.w900,
                              ),
                        ),
                        const SizedBox(height: 6),
                        Text(
                          'Getting a fresh hello ready',
                          textAlign: TextAlign.center,
                          style: Theme.of(context).textTheme.bodyMedium
                              ?.copyWith(
                                color: const Color(0xFF65596E),
                                fontWeight: FontWeight.w700,
                              ),
                        ),
                        const Spacer(flex: 2),
                      ],
                    ),
                  ),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: <Widget>[
                      _CallControlButton(
                        icon: Icons.call_end_rounded,
                        color: const Color(0xFFE53935),
                        onTap: onCancel,
                        large: true,
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _RingingPhone extends StatefulWidget {
  const _RingingPhone({required this.color});

  final Color color;

  @override
  State<_RingingPhone> createState() => _RingingPhoneState();
}

class _RingingPhoneState extends State<_RingingPhone>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 920),
    )..repeat();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 132,
      height: 132,
      child: AnimatedBuilder(
        animation: _controller,
        builder: (BuildContext context, Widget? child) {
          final double t = _controller.value;
          return Stack(
            alignment: Alignment.center,
            children: <Widget>[
              for (int index = 0; index < 2; index += 1)
                _PhonePulseRing(
                  progress: (t + index * 0.48) % 1,
                  color: widget.color,
                ),
              Transform.rotate(
                angle: math.sin(t * math.pi * 6) * 0.13,
                child: Container(
                  width: 76,
                  height: 76,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: widget.color,
                    boxShadow: <BoxShadow>[
                      BoxShadow(
                        color: widget.color.withValues(alpha: 0.34),
                        blurRadius: 22,
                        offset: const Offset(0, 10),
                      ),
                    ],
                  ),
                  child: const Icon(
                    Icons.phone_in_talk_rounded,
                    color: Colors.white,
                    size: 38,
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

class _PhonePulseRing extends StatelessWidget {
  const _PhonePulseRing({required this.progress, required this.color});

  final double progress;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Opacity(
      opacity: (1 - progress).clamp(0.0, 1.0) * 0.42,
      child: Transform.scale(
        scale: 0.72 + progress * 0.58,
        child: Container(
          width: 92,
          height: 92,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            border: Border.all(color: color.withValues(alpha: 0.76), width: 3),
          ),
        ),
      ),
    );
  }
}

class _ConnectionSettings extends StatelessWidget {
  const _ConnectionSettings({required this.controller, required this.enabled});

  final TextEditingController controller;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    return Theme(
      data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
      child: Material(
        color: Colors.white.withValues(alpha: 0.58),
        borderRadius: BorderRadius.circular(14),
        clipBehavior: Clip.antiAlias,
        child: ExpansionTile(
          tilePadding: const EdgeInsets.symmetric(horizontal: 14),
          childrenPadding: const EdgeInsets.fromLTRB(14, 0, 14, 12),
          leading: const Icon(Icons.dns_rounded, size: 20),
          title: const Text(
            'Connection',
            style: TextStyle(fontWeight: FontWeight.w700),
          ),
          children: <Widget>[
            TextField(
              controller: controller,
              enabled: enabled,
              keyboardType: TextInputType.url,
              decoration: const InputDecoration(
                labelText: 'Server',
                border: OutlineInputBorder(),
                isDense: true,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SettingsSheet extends StatefulWidget {
  const _SettingsSheet({
    required this.firstVoiceWaitSeconds,
    required this.endWaitSeconds,
    required this.loadingPersonas,
    required this.onRefreshPersonas,
  });

  final double firstVoiceWaitSeconds;
  final double endWaitSeconds;
  final bool loadingPersonas;
  final Future<void> Function() onRefreshPersonas;

  @override
  State<_SettingsSheet> createState() => _SettingsSheetState();
}

class _SettingsSheetState extends State<_SettingsSheet> {
  late double _firstVoiceWaitSeconds;
  late double _endWaitSeconds;
  late bool _refreshingPersonas;

  @override
  void initState() {
    super.initState();
    _firstVoiceWaitSeconds = widget.firstVoiceWaitSeconds;
    _endWaitSeconds = widget.endWaitSeconds;
    _refreshingPersonas = widget.loadingPersonas;
  }

  Future<void> _refreshPersonas() async {
    if (_refreshingPersonas) {
      return;
    }
    setState(() {
      _refreshingPersonas = true;
    });
    try {
      await widget.onRefreshPersonas();
    } finally {
      if (mounted) {
        setState(() {
          _refreshingPersonas = false;
        });
      }
    }
  }

  void _apply() {
    Navigator.of(context).pop(
      _FadTimingSettings(
        firstVoiceWaitSeconds: _firstVoiceWaitSeconds,
        endWaitSeconds: _endWaitSeconds,
      ),
    );
  }

  void _reset() {
    setState(() {
      _firstVoiceWaitSeconds = _defaultFirstVoiceWaitSeconds;
      _endWaitSeconds = _defaultEndWaitSeconds;
    });
  }

  @override
  Widget build(BuildContext context) {
    final EdgeInsets viewInsets = MediaQuery.viewInsetsOf(context);
    return SafeArea(
      top: false,
      child: Padding(
        padding: EdgeInsets.fromLTRB(22, 4, 22, 18 + viewInsets.bottom),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Row(
              children: <Widget>[
                const Icon(Icons.settings_rounded, color: Color(0xFF50366F)),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    'Settings',
                    style: Theme.of(context).textTheme.titleLarge?.copyWith(
                      color: const Color(0xFF2C2434),
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                ),
                IconButton(
                  tooltip: 'Close',
                  onPressed: () => Navigator.of(context).pop(),
                  icon: const Icon(Icons.close_rounded),
                ),
              ],
            ),
            const SizedBox(height: 10),
            _TimingSlider(
              icon: Icons.record_voice_over_rounded,
              title: 'Start audio wait',
              value: _firstVoiceWaitSeconds,
              min: _minFirstVoiceWaitSeconds,
              max: _maxFirstVoiceWaitSeconds,
              divisions: 9,
              suffix: 's',
              onChanged: (double value) {
                setState(() {
                  _firstVoiceWaitSeconds = value.roundToDouble();
                });
              },
            ),
            const SizedBox(height: 12),
            _TimingSlider(
              icon: Icons.hearing_disabled_rounded,
              title: 'End wait',
              value: _endWaitSeconds,
              min: _minEndWaitSeconds,
              max: _maxEndWaitSeconds,
              divisions: 36,
              suffix: 's',
              onChanged: (double value) {
                setState(() {
                  _endWaitSeconds = double.parse(value.toStringAsFixed(1));
                });
              },
            ),
            const SizedBox(height: 14),
            OutlinedButton.icon(
              onPressed: _refreshingPersonas
                  ? null
                  : () => unawaited(_refreshPersonas()),
              icon: Icon(
                _refreshingPersonas
                    ? Icons.hourglass_top_rounded
                    : Icons.refresh_rounded,
              ),
              label: Text(
                _refreshingPersonas
                    ? 'Refreshing personas'
                    : 'Refresh personas',
              ),
            ),
            const SizedBox(height: 12),
            Row(
              children: <Widget>[
                TextButton.icon(
                  onPressed: _reset,
                  icon: const Icon(Icons.restart_alt_rounded),
                  label: const Text('Reset'),
                ),
                const Spacer(),
                FilledButton.icon(
                  onPressed: _apply,
                  icon: const Icon(Icons.check_rounded),
                  label: const Text('Apply'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _TimingSlider extends StatelessWidget {
  const _TimingSlider({
    required this.icon,
    required this.title,
    required this.value,
    required this.min,
    required this.max,
    required this.divisions,
    required this.suffix,
    required this.onChanged,
  });

  final IconData icon;
  final String title;
  final double value;
  final double min;
  final double max;
  final int divisions;
  final String suffix;
  final ValueChanged<double> onChanged;

  @override
  Widget build(BuildContext context) {
    final String displayValue = '${_formatSeconds(value)}$suffix';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Row(
          children: <Widget>[
            Icon(icon, size: 20, color: const Color(0xFF50366F)),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                title,
                style: const TextStyle(
                  color: Color(0xFF2C2434),
                  fontWeight: FontWeight.w800,
                ),
              ),
            ),
            Text(
              displayValue,
              style: const TextStyle(
                color: Color(0xFF50366F),
                fontWeight: FontWeight.w900,
              ),
            ),
          ],
        ),
        Slider(
          value: value.clamp(min, max).toDouble(),
          min: min,
          max: max,
          divisions: divisions,
          label: displayValue,
          onChanged: onChanged,
        ),
      ],
    );
  }
}

class _GuidedStoryWizardScreen extends StatelessWidget {
  const _GuidedStoryWizardScreen({
    required this.visual,
    required this.wizardId,
    required this.phase,
    required this.phaseColor,
    required this.status,
    required this.intro,
    required this.introFinished,
    required this.questionsStarted,
    required this.state,
    required this.storyText,
    required this.generatingStory,
    required this.busy,
    required this.liveSubtitleText,
    required this.liveSubtitleActiveWordIndex,
    required this.onIntroReady,
    required this.onSkipIntro,
    required this.onChoiceSelected,
    required this.onAbort,
  });

  final PersonaVisual visual;
  final String wizardId;
  final CallPhase phase;
  final Color phaseColor;
  final String status;
  final TalkWizardIntro? intro;
  final bool introFinished;
  final bool questionsStarted;
  final TalkWizardState? state;
  final String storyText;
  final bool generatingStory;
  final bool busy;
  final String liveSubtitleText;
  final int liveSubtitleActiveWordIndex;
  final VoidCallback onIntroReady;
  final VoidCallback onSkipIntro;
  final ValueChanged<TalkWizardChoice> onChoiceSelected;
  final VoidCallback onAbort;

  @override
  Widget build(BuildContext context) {
    final TalkWizardIntro? currentIntro = intro;
    final TalkWizardState? currentState = state;
    final bool calling =
        busy &&
        currentIntro == null &&
        currentState == null &&
        !generatingStory &&
        storyText.trim().isEmpty;
    final bool showingIntro =
        currentIntro != null &&
        currentIntro.prompt.trim().isNotEmpty &&
        !questionsStarted &&
        !generatingStory &&
        storyText.trim().isEmpty;
    final bool showingQuestion =
        questionsStarted &&
        currentState != null &&
        !generatingStory &&
        storyText.trim().isEmpty;
    final String? wizardBackgroundAsset = StoryWizardAssets.backgroundFor(
      wizardId,
    );
    final String? wizardPersonaAsset = StoryWizardAssets.personaFor(wizardId);
    final String? wizardHelperAsset = StoryWizardAssets.helperFor(wizardId);
    final bool hasWizardScene = wizardBackgroundAsset != null;
    final bool useQuestionScene = showingQuestion && hasWizardScene;

    return Scaffold(
      body: Stack(
        children: <Widget>[
          Positioned.fill(
            child: Image(
              image: AssetImage(wizardBackgroundAsset ?? _appBackgroundAsset),
              fit: BoxFit.cover,
            ),
          ),
          Positioned.fill(
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: <Color>[
                    Colors.white.withValues(alpha: 0.10),
                    visual.color.withValues(alpha: 0.12),
                    const Color(0xFF1F1634).withValues(alpha: 0.38),
                  ],
                ),
              ),
            ),
          ),
          SafeArea(
            child: Column(
              children: <Widget>[
                Padding(
                  padding: const EdgeInsets.fromLTRB(18, 12, 18, 4),
                  child: Row(
                    children: <Widget>[
                      SizedBox(
                        width: 48,
                        height: 48,
                        child: _PersonaAvatar(
                          visual: visual,
                          selected: true,
                          padding: 2,
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: <Widget>[
                            Text(
                              visual.fullName,
                              overflow: TextOverflow.ellipsis,
                              style: Theme.of(context).textTheme.titleMedium
                                  ?.copyWith(
                                    color: hasWizardScene
                                        ? Colors.white
                                        : const Color(0xFF2C2434),
                                    fontWeight: FontWeight.w900,
                                    shadows: hasWizardScene
                                        ? const <Shadow>[
                                            Shadow(
                                              color: Color(0xAA080418),
                                              blurRadius: 8,
                                              offset: Offset(0, 2),
                                            ),
                                          ]
                                        : null,
                                  ),
                            ),
                            const SizedBox(height: 3),
                            _StatusPill(status: status, color: phaseColor),
                          ],
                        ),
                      ),
                      _RoundGlyphButton(
                        icon: Icons.close_rounded,
                        color: const Color(0xFFD84A4A),
                        onTap: onAbort,
                      ),
                    ],
                  ),
                ),
                Expanded(
                  child: AnimatedSwitcher(
                    duration: const Duration(milliseconds: 260),
                    child: useQuestionScene
                        ? _WizardQuestionScene(
                            key: ValueKey<String>(
                              'wizard-scene-${currentState.stateId}',
                            ),
                            wizardId: wizardId,
                            personaAssetPath: wizardPersonaAsset,
                            helperAssetPath: wizardHelperAsset,
                            state: currentState,
                            busy: busy,
                            onChoiceSelected: onChoiceSelected,
                          )
                        : Center(
                            child: calling
                                ? _WizardCallingStage(
                                    visual: visual,
                                    phaseColor: phaseColor,
                                  )
                                : _CallPersonaStage(
                                    visual: visual,
                                    phase: phase,
                                    phaseColor: phaseColor,
                                    micLevel: 0,
                                    imageAssetOverride: wizardPersonaAsset,
                                    onTap: () {},
                                  ),
                          ),
                  ),
                ),
                if (!useQuestionScene && liveSubtitleText.trim().isNotEmpty)
                  _LiveAudioCaption(
                    caption: liveSubtitleText,
                    color: phaseColor,
                    activeWordIndex: liveSubtitleActiveWordIndex,
                  ),
                if (!useQuestionScene)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(18, 0, 18, 18),
                    child: AnimatedSwitcher(
                      duration: const Duration(milliseconds: 220),
                      child: calling
                          ? _WizardCallingPanel(
                              key: const ValueKey<String>('wizard-calling'),
                              visual: visual,
                            )
                          : showingIntro
                          ? _WizardIntroPanel(
                              key: const ValueKey<String>('wizard-intro'),
                              intro: currentIntro,
                              introFinished: introFinished,
                              showSkip:
                                  !introFinished && currentIntro.skipAllowed,
                              onReady: onIntroReady,
                              onSkip: onSkipIntro,
                            )
                          : showingQuestion
                          ? _WizardQuestionPanel(
                              key: ValueKey<String>(
                                'wizard-question-${currentState.stateId}',
                              ),
                              wizardId: wizardId,
                              state: currentState,
                              busy: busy,
                              onChoiceSelected: onChoiceSelected,
                            )
                          : generatingStory
                          ? const _WizardGeneratingPanel(
                              key: ValueKey<String>('wizard-generating'),
                            )
                          : _WizardStoryPanel(
                              key: const ValueKey<String>('wizard-story'),
                              storyText: storyText,
                            ),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _WizardIntroPanel extends StatelessWidget {
  const _WizardIntroPanel({
    required this.intro,
    required this.introFinished,
    required this.showSkip,
    required this.onReady,
    required this.onSkip,
    super.key,
  });

  final TalkWizardIntro intro;
  final bool introFinished;
  final bool showSkip;
  final VoidCallback onReady;
  final VoidCallback onSkip;

  @override
  Widget build(BuildContext context) {
    return _WizardBottomCard(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Text(
            intro.prompt,
            maxLines: 5,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
              color: const Color(0xFF2C2434),
              fontWeight: FontWeight.w700,
              height: 1.28,
            ),
          ),
          const SizedBox(height: 12),
          FilledButton.icon(
            onPressed: introFinished
                ? onReady
                : showSkip
                ? onSkip
                : null,
            icon: Icon(
              introFinished
                  ? Icons.check_circle_rounded
                  : showSkip
                  ? Icons.fast_forward_rounded
                  : Icons.hearing,
            ),
            label: Text(
              introFinished
                  ? 'I am ready'
                  : showSkip
                  ? intro.skipLabel
                  : 'Listen first',
            ),
          ),
        ],
      ),
    );
  }
}

class _WizardCallingStage extends StatefulWidget {
  const _WizardCallingStage({required this.visual, required this.phaseColor});

  final PersonaVisual visual;
  final Color phaseColor;

  @override
  State<_WizardCallingStage> createState() => _WizardCallingStageState();
}

class _WizardCallingStageState extends State<_WizardCallingStage>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1500),
  )..repeat();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final Size screenSize = MediaQuery.sizeOf(context);
        final double maxWidth = constraints.maxWidth.isFinite
            ? constraints.maxWidth
            : screenSize.width;
        final double maxHeight = constraints.maxHeight.isFinite
            ? constraints.maxHeight
            : screenSize.height * 0.58;
        final double size = math.min(
          math.min(maxWidth * 0.62, maxHeight * 0.62),
          250,
        );

        return SizedBox(
          width: size + 96,
          height: size + 96,
          child: AnimatedBuilder(
            animation: _controller,
            builder: (BuildContext context, Widget? child) {
              return Stack(
                alignment: Alignment.center,
                children: <Widget>[
                  for (int index = 0; index < 3; index += 1)
                    _CallingRing(
                      progress: (_controller.value + index / 3) % 1,
                      color: widget.phaseColor,
                      size: size,
                    ),
                  Container(
                    width: size,
                    height: size,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      gradient: RadialGradient(
                        colors: <Color>[
                          Colors.white.withValues(alpha: 0.96),
                          widget.visual.color.withValues(alpha: 0.24),
                        ],
                      ),
                      border: Border.all(
                        color: widget.phaseColor.withValues(alpha: 0.55),
                        width: 4,
                      ),
                      boxShadow: <BoxShadow>[
                        BoxShadow(
                          color: widget.visual.color.withValues(alpha: 0.28),
                          blurRadius: 30,
                          offset: const Offset(0, 14),
                        ),
                      ],
                    ),
                    child: Icon(
                      Icons.phone_in_talk_rounded,
                      color: widget.phaseColor,
                      size: size * 0.34,
                    ),
                  ),
                ],
              );
            },
          ),
        );
      },
    );
  }
}

class _CallingRing extends StatelessWidget {
  const _CallingRing({
    required this.progress,
    required this.color,
    required this.size,
  });

  final double progress;
  final Color color;
  final double size;

  @override
  Widget build(BuildContext context) {
    final double eased = Curves.easeOut.transform(progress);
    return Container(
      width: size + eased * 86,
      height: size + eased * 86,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        border: Border.all(
          color: color.withValues(alpha: (1 - eased) * 0.42),
          width: 3,
        ),
      ),
    );
  }
}

class _WizardCallingPanel extends StatelessWidget {
  const _WizardCallingPanel({required this.visual, super.key});

  final PersonaVisual visual;

  @override
  Widget build(BuildContext context) {
    return _WizardBottomCard(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          const _WizardMagicLoader(),
          const SizedBox(height: 12),
          Text(
            'Calling ${visual.displayName}...',
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.titleMedium?.copyWith(
              color: const Color(0xFF2C2434),
              fontWeight: FontWeight.w900,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            'Preparing the storyteller voice. The wizard will appear when ready.',
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: const Color(0xFF65596E),
              fontWeight: FontWeight.w700,
              height: 1.25,
            ),
          ),
        ],
      ),
    );
  }
}

class _WizardQuestionScene extends StatelessWidget {
  const _WizardQuestionScene({
    required this.wizardId,
    required this.personaAssetPath,
    required this.helperAssetPath,
    required this.state,
    required this.busy,
    required this.onChoiceSelected,
    super.key,
  });

  final String wizardId;
  final String? personaAssetPath;
  final String? helperAssetPath;
  final TalkWizardState state;
  final bool busy;
  final ValueChanged<TalkWizardChoice> onChoiceSelected;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final double width = constraints.maxWidth;
        final double height = constraints.maxHeight;
        final double safeWidth = width.isFinite && width > 0 ? width : 390;
        final double safeHeight = height.isFinite && height > 0 ? height : 640;
        final List<_WizardChoiceSpot> spots = _WizardChoiceSpot.forCount(
          state.choices.length,
        );
        final double nodeWidth = math.min(146, safeWidth * 0.34);
        final double personaWidth = math.min(176, safeWidth * 0.43);
        final double helperSize = math.min(74, safeWidth * 0.18);

        return Stack(
          clipBehavior: Clip.none,
          children: <Widget>[
            Positioned(
              top: 2,
              left: 22,
              right: 22,
              child: _WizardProgressPath(stepIndex: state.stepIndex),
            ),
            Positioned(
              top: 48,
              left: 20,
              right: 20,
              child: _WizardScenePromptBubble(
                text: state.spokenPrompt.isNotEmpty
                    ? state.spokenPrompt
                    : state.prompt,
              ),
            ),
            if (personaAssetPath != null)
              Positioned(
                left: -safeWidth * 0.06,
                top: safeHeight * 0.18,
                width: personaWidth,
                child: IgnorePointer(
                  child: Image.asset(
                    personaAssetPath!,
                    fit: BoxFit.contain,
                    filterQuality: FilterQuality.high,
                  ),
                ),
              ),
            if (helperAssetPath != null)
              Positioned(
                right: 24,
                top: safeHeight * 0.22,
                width: helperSize,
                height: helperSize,
                child: IgnorePointer(
                  child: Image.asset(
                    helperAssetPath!,
                    fit: BoxFit.contain,
                    filterQuality: FilterQuality.high,
                  ),
                ),
              ),
            for (int index = 0; index < state.choices.length; index += 1)
              _PositionedWizardChoice(
                wizardId: wizardId,
                state: state,
                choice: state.choices[index],
                enabled: !busy,
                index: index,
                spot: spots[index],
                nodeWidth: nodeWidth * spots[index].scale,
                stageWidth: safeWidth,
                stageHeight: safeHeight,
                onTap: () => onChoiceSelected(state.choices[index]),
              ),
          ],
        );
      },
    );
  }
}

class _WizardChoiceSpot {
  const _WizardChoiceSpot(this.x, this.y, [this.scale = 1]);

  final double x;
  final double y;
  final double scale;

  static List<_WizardChoiceSpot> forCount(int count) {
    if (count <= 3) {
      return const <_WizardChoiceSpot>[
        _WizardChoiceSpot(0.28, 0.56),
        _WizardChoiceSpot(0.72, 0.56),
        _WizardChoiceSpot(0.50, 0.80, 1.04),
      ].take(count).toList();
    }
    if (count == 4) {
      return const <_WizardChoiceSpot>[
        _WizardChoiceSpot(0.28, 0.52),
        _WizardChoiceSpot(0.72, 0.51),
        _WizardChoiceSpot(0.30, 0.78),
        _WizardChoiceSpot(0.72, 0.79),
      ];
    }
    if (count == 5) {
      return const <_WizardChoiceSpot>[
        _WizardChoiceSpot(0.50, 0.43, 0.96),
        _WizardChoiceSpot(0.25, 0.62),
        _WizardChoiceSpot(0.75, 0.62),
        _WizardChoiceSpot(0.35, 0.84, 0.94),
        _WizardChoiceSpot(0.68, 0.84, 0.94),
      ];
    }
    if (count == 6) {
      return const <_WizardChoiceSpot>[
        _WizardChoiceSpot(0.25, 0.45, 0.88),
        _WizardChoiceSpot(0.55, 0.43, 0.88),
        _WizardChoiceSpot(0.78, 0.55, 0.88),
        _WizardChoiceSpot(0.25, 0.72, 0.88),
        _WizardChoiceSpot(0.55, 0.76, 0.88),
        _WizardChoiceSpot(0.78, 0.84, 0.86),
      ];
    }
    return List<_WizardChoiceSpot>.generate(count, (int index) {
      const int columns = 3;
      final int row = index ~/ columns;
      final int col = index % columns;
      return _WizardChoiceSpot(
        0.22 + col * 0.28,
        math.min(0.86, 0.44 + row * 0.19),
        0.82,
      );
    });
  }
}

class _PositionedWizardChoice extends StatelessWidget {
  const _PositionedWizardChoice({
    required this.wizardId,
    required this.state,
    required this.choice,
    required this.enabled,
    required this.index,
    required this.spot,
    required this.nodeWidth,
    required this.stageWidth,
    required this.stageHeight,
    required this.onTap,
  });

  final String wizardId;
  final TalkWizardState state;
  final TalkWizardChoice choice;
  final bool enabled;
  final int index;
  final _WizardChoiceSpot spot;
  final double nodeWidth;
  final double stageWidth;
  final double stageHeight;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final double nodeHeight = nodeWidth + 46;
    final double left = (stageWidth * spot.x - nodeWidth / 2).clamp(
      8,
      math.max(8, stageWidth - nodeWidth - 8),
    );
    final double top = (stageHeight * spot.y - nodeHeight / 2).clamp(
      120,
      math.max(120, stageHeight - nodeHeight - 8),
    );

    return Positioned(
      left: left.toDouble(),
      top: top.toDouble(),
      width: nodeWidth,
      child: _WizardFloatingChoiceButton(
        wizardId: wizardId,
        state: state,
        choice: choice,
        enabled: enabled,
        index: index,
        onTap: onTap,
      ),
    );
  }
}

class _WizardScenePromptBubble extends StatelessWidget {
  const _WizardScenePromptBubble({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(18, 14, 18, 16),
      decoration: BoxDecoration(
        color: const Color(0xFFFFF3D7).withValues(alpha: 0.96),
        borderRadius: BorderRadius.circular(26),
        border: Border.all(color: const Color(0xFF8EE9FF), width: 2.4),
        boxShadow: <BoxShadow>[
          BoxShadow(
            color: const Color(0xFF46CCFF).withValues(alpha: 0.28),
            blurRadius: 18,
            spreadRadius: 1,
          ),
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.22),
            blurRadius: 16,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: Text(
        text,
        maxLines: 3,
        overflow: TextOverflow.ellipsis,
        textAlign: TextAlign.center,
        style: Theme.of(context).textTheme.titleLarge?.copyWith(
          color: const Color(0xFF352387),
          fontWeight: FontWeight.w900,
          height: 1.12,
        ),
      ),
    );
  }
}

class _WizardProgressPath extends StatelessWidget {
  const _WizardProgressPath({required this.stepIndex});

  final int stepIndex;

  static const int _totalSteps = 7;

  @override
  Widget build(BuildContext context) {
    final int active = stepIndex.clamp(1, _totalSteps);
    return Row(
      children: List<Widget>.generate(_totalSteps * 2 - 1, (int index) {
        if (index.isOdd) {
          final bool completed = index ~/ 2 + 1 < active;
          return Expanded(
            child: Container(
              height: 3,
              decoration: BoxDecoration(
                color: (completed ? const Color(0xFFFFD35A) : Colors.white)
                    .withValues(alpha: completed ? 0.86 : 0.38),
                borderRadius: BorderRadius.circular(999),
              ),
            ),
          );
        }
        final int dot = index ~/ 2 + 1;
        final bool completed = dot < active;
        final bool current = dot == active;
        return Container(
          width: current ? 30 : 22,
          height: current ? 30 : 22,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: current
                ? const Color(0xFFFFD35A)
                : completed
                ? const Color(0xFF8EE9FF)
                : const Color(0xFF3D316B).withValues(alpha: 0.80),
            border: Border.all(
              color: Colors.white.withValues(alpha: current ? 0.96 : 0.62),
              width: 2,
            ),
            boxShadow: current
                ? <BoxShadow>[
                    BoxShadow(
                      color: const Color(0xFFFFD35A).withValues(alpha: 0.62),
                      blurRadius: 16,
                    ),
                  ]
                : null,
          ),
          child: current
              ? const Icon(
                  Icons.star_rounded,
                  color: Color(0xFF5A2C00),
                  size: 18,
                )
              : null,
        );
      }),
    );
  }
}

class _WizardFloatingChoiceButton extends StatelessWidget {
  const _WizardFloatingChoiceButton({
    required this.wizardId,
    required this.state,
    required this.choice,
    required this.enabled,
    required this.index,
    required this.onTap,
  });

  final String wizardId;
  final TalkWizardState state;
  final TalkWizardChoice choice;
  final bool enabled;
  final int index;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final String? assetPath = StoryWizardAssets.choiceFor(
      wizardId: wizardId,
      choiceId: choice.choiceId,
      imageAssetPath: choice.imageAssetPath,
    );
    if (assetPath == null) {
      return _WizardChoiceButton(
        wizardId: wizardId,
        state: state,
        choice: choice,
        enabled: enabled,
        onTap: onTap,
      );
    }
    final Color glow = _choiceGlow(index);
    return TweenAnimationBuilder<double>(
      tween: Tween<double>(begin: 0, end: 1),
      duration: Duration(milliseconds: 360 + index * 70),
      curve: Curves.easeOutBack,
      builder: (BuildContext context, double value, Widget? child) {
        return Opacity(
          opacity: value.clamp(0.0, 1.0),
          child: Transform.translate(
            offset: Offset(0, (1 - value) * 20),
            child: Transform.scale(scale: 0.90 + 0.10 * value, child: child),
          ),
        );
      },
      child: Opacity(
        opacity: enabled ? 1 : 0.58,
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            borderRadius: BorderRadius.circular(999),
            onTap: enabled ? onTap : null,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Container(
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    boxShadow: <BoxShadow>[
                      BoxShadow(
                        color: glow.withValues(alpha: 0.82),
                        blurRadius: 24,
                        spreadRadius: 2,
                      ),
                      BoxShadow(
                        color: Colors.black.withValues(alpha: 0.30),
                        blurRadius: 16,
                        offset: const Offset(0, 9),
                      ),
                    ],
                  ),
                  child: ClipOval(
                    child: AspectRatio(
                      aspectRatio: 1,
                      child: Image.asset(
                        assetPath,
                        fit: BoxFit.cover,
                        filterQuality: FilterQuality.high,
                        errorBuilder:
                            (
                              BuildContext context,
                              Object error,
                              StackTrace? stackTrace,
                            ) => ColoredBox(
                              color: glow.withValues(alpha: 0.24),
                              child: const Icon(
                                Icons.auto_awesome_rounded,
                                color: Colors.white,
                                size: 34,
                              ),
                            ),
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 7),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 7,
                  ),
                  decoration: BoxDecoration(
                    color: glow.withValues(alpha: 0.90),
                    borderRadius: BorderRadius.circular(999),
                    border: Border.all(
                      color: Colors.white.withValues(alpha: 0.78),
                      width: 1.4,
                    ),
                    boxShadow: <BoxShadow>[
                      BoxShadow(
                        color: glow.withValues(alpha: 0.38),
                        blurRadius: 12,
                        offset: const Offset(0, 5),
                      ),
                    ],
                  ),
                  child: Text(
                    choice.label,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.labelLarge?.copyWith(
                      color: Colors.white,
                      fontWeight: FontWeight.w900,
                      height: 1.05,
                      shadows: const <Shadow>[
                        Shadow(
                          color: Color(0x99000000),
                          blurRadius: 4,
                          offset: Offset(0, 1),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Color _choiceGlow(int index) {
    const List<Color> colors = <Color>[
      Color(0xFF00C8FF),
      Color(0xFF9B5CFF),
      Color(0xFF00B875),
      Color(0xFFFF7A24),
      Color(0xFFFFD35A),
      Color(0xFFE248FF),
    ];
    return colors[index % colors.length];
  }
}

class _WizardQuestionPanel extends StatelessWidget {
  const _WizardQuestionPanel({
    required this.wizardId,
    required this.state,
    required this.busy,
    required this.onChoiceSelected,
    super.key,
  });

  final String wizardId;
  final TalkWizardState state;
  final bool busy;
  final ValueChanged<TalkWizardChoice> onChoiceSelected;

  @override
  Widget build(BuildContext context) {
    return _WizardBottomCard(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Text(
            state.spokenPrompt.isNotEmpty ? state.spokenPrompt : state.prompt,
            style: Theme.of(context).textTheme.titleMedium?.copyWith(
              color: const Color(0xFF2C2434),
              fontWeight: FontWeight.w900,
              height: 1.22,
            ),
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 9,
            runSpacing: 9,
            alignment: WrapAlignment.center,
            children: state.choices
                .map(
                  (TalkWizardChoice choice) => _WizardChoiceButton(
                    wizardId: wizardId,
                    state: state,
                    choice: choice,
                    enabled: !busy,
                    onTap: () => onChoiceSelected(choice),
                  ),
                )
                .toList(),
          ),
        ],
      ),
    );
  }
}

class _WizardChoiceButton extends StatelessWidget {
  const _WizardChoiceButton({
    required this.wizardId,
    required this.state,
    required this.choice,
    required this.enabled,
    required this.onTap,
  });

  final String wizardId;
  final TalkWizardState state;
  final TalkWizardChoice choice;
  final bool enabled;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final String? assetPath = StoryWizardAssets.choiceFor(
      wizardId: wizardId,
      choiceId: choice.choiceId,
      imageAssetPath: choice.imageAssetPath,
    );
    if (assetPath != null) {
      return _WizardImageChoiceButton(
        label: choice.label,
        assetPath: assetPath,
        enabled: enabled,
        onTap: onTap,
      );
    }
    return FilledButton(
      onPressed: enabled ? onTap : null,
      style: FilledButton.styleFrom(
        backgroundColor: const Color(0xFFFFD35A),
        foregroundColor: const Color(0xFF50310A),
        disabledBackgroundColor: const Color(0xFFE5DFD0),
        disabledForegroundColor: const Color(0xFF827A6E),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
      ),
      child: Text(
        choice.label,
        style: const TextStyle(fontWeight: FontWeight.w900),
      ),
    );
  }
}

class _WizardImageChoiceButton extends StatelessWidget {
  const _WizardImageChoiceButton({
    required this.label,
    required this.assetPath,
    required this.enabled,
    required this.onTap,
  });

  final String label;
  final String assetPath;
  final bool enabled;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Opacity(
      opacity: enabled ? 1 : 0.58,
      child: SizedBox(
        width: 112,
        child: Material(
          color: const Color(0xFFFFFBED),
          borderRadius: BorderRadius.circular(18),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: enabled ? onTap : null,
            child: Container(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(18),
                border: Border.all(color: const Color(0xFFF7C948), width: 2),
                boxShadow: <BoxShadow>[
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.10),
                    blurRadius: 10,
                    offset: const Offset(0, 5),
                  ),
                ],
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  AspectRatio(
                    aspectRatio: 1,
                    child: Image.asset(
                      assetPath,
                      fit: BoxFit.cover,
                      filterQuality: FilterQuality.high,
                      errorBuilder:
                          (
                            BuildContext context,
                            Object error,
                            StackTrace? stackTrace,
                          ) => const ColoredBox(
                            color: Color(0xFFFFE8A3),
                            child: Icon(
                              Icons.auto_awesome_rounded,
                              color: Color(0xFF7A4A00),
                              size: 34,
                            ),
                          ),
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(8, 8, 8, 10),
                    child: Text(
                      label,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      textAlign: TextAlign.center,
                      style: Theme.of(context).textTheme.labelMedium?.copyWith(
                        color: const Color(0xFF50310A),
                        fontWeight: FontWeight.w900,
                        height: 1.08,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _WizardGeneratingPanel extends StatelessWidget {
  const _WizardGeneratingPanel({super.key});

  @override
  Widget build(BuildContext context) {
    return _WizardBottomCard(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          const _WizardMagicLoader(),
          const SizedBox(height: 12),
          Text(
            'Your story is being woven...',
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.titleMedium?.copyWith(
              color: const Color(0xFF2C2434),
              fontWeight: FontWeight.w900,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            'This can take a little while. The full story will play when it arrives.',
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: const Color(0xFF65596E),
              fontWeight: FontWeight.w700,
              height: 1.25,
            ),
          ),
        ],
      ),
    );
  }
}

class _WizardStoryPanel extends StatelessWidget {
  const _WizardStoryPanel({required this.storyText, super.key});

  final String storyText;

  @override
  Widget build(BuildContext context) {
    final String text = storyText.trim();
    return _WizardBottomCard(
      child: Text(
        text.isEmpty ? 'Getting ready...' : text,
        maxLines: 5,
        overflow: TextOverflow.ellipsis,
        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
          color: const Color(0xFF2C2434),
          fontWeight: FontWeight.w700,
          height: 1.28,
        ),
      ),
    );
  }
}

class _WizardBottomCard extends StatelessWidget {
  const _WizardBottomCard({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      constraints: const BoxConstraints(maxWidth: 620),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.92),
        borderRadius: BorderRadius.circular(22),
        border: Border.all(
          color: const Color(0xFFF7C948).withValues(alpha: 0.76),
          width: 2,
        ),
        boxShadow: <BoxShadow>[
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.16),
            blurRadius: 18,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: child,
    );
  }
}

class _WizardMagicLoader extends StatefulWidget {
  const _WizardMagicLoader();

  @override
  State<_WizardMagicLoader> createState() => _WizardMagicLoaderState();
}

class _WizardMagicLoaderState extends State<_WizardMagicLoader>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1400),
  )..repeat();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (BuildContext context, Widget? child) {
        return Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: List<Widget>.generate(5, (int index) {
            final double wave = math.sin(
              (_controller.value * 2 * math.pi) + index * 0.7,
            );
            return Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4),
              child: Transform.translate(
                offset: Offset(0, -5 * wave),
                child: Icon(
                  Icons.auto_awesome_rounded,
                  color: Color.lerp(
                    const Color(0xFFE0A82E),
                    const Color(0xFF6C5CE7),
                    (wave + 1) / 2,
                  ),
                  size: 22 + (wave + 1) * 2,
                ),
              ),
            );
          }),
        );
      },
    );
  }
}

class _CallExperienceScreen extends StatelessWidget {
  const _CallExperienceScreen({
    required this.visual,
    required this.phase,
    required this.phaseColor,
    required this.status,
    required this.micLevel,
    required this.eventCount,
    required this.micBytes,
    required this.micFrames,
    required this.nativeMicBytes,
    required this.nativeMicFrames,
    required this.nativeAudioSource,
    required this.nativeVadSource,
    required this.nativeVadMode,
    required this.audioBytes,
    required this.transcriptController,
    required this.userText,
    required this.assistantText,
    required this.liveAudioCaption,
    required this.liveSubtitleText,
    required this.liveSubtitleActiveWordIndex,
    required this.metrics,
    required this.events,
    required this.textController,
    required this.textEnabled,
    required this.canStopAudio,
    required this.onMainButtonTap,
    required this.onStopAudio,
    required this.onEndCall,
    required this.onSendText,
    required this.onTestAudio,
  });

  final PersonaVisual visual;
  final CallPhase phase;
  final Color phaseColor;
  final String status;
  final double micLevel;
  final int eventCount;
  final int micBytes;
  final int micFrames;
  final int nativeMicBytes;
  final int nativeMicFrames;
  final String nativeAudioSource;
  final String nativeVadSource;
  final String nativeVadMode;
  final int audioBytes;
  final ScrollController transcriptController;
  final String userText;
  final String assistantText;
  final String liveAudioCaption;
  final String liveSubtitleText;
  final int liveSubtitleActiveWordIndex;
  final Map<String, Object?> metrics;
  final List<String> events;
  final TextEditingController textController;
  final bool textEnabled;
  final bool canStopAudio;
  final VoidCallback onMainButtonTap;
  final VoidCallback onStopAudio;
  final VoidCallback onEndCall;
  final VoidCallback onSendText;
  final VoidCallback onTestAudio;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      resizeToAvoidBottomInset: true,
      body: Stack(
        children: <Widget>[
          const Positioned.fill(
            child: Image(
              image: AssetImage(_appBackgroundAsset),
              fit: BoxFit.cover,
            ),
          ),
          Positioned.fill(
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: <Color>[
                    Colors.white.withValues(alpha: 0.10),
                    visual.color.withValues(alpha: 0.10),
                    const Color(0xFF1F1634).withValues(alpha: 0.34),
                  ],
                ),
              ),
            ),
          ),
          SafeArea(
            child: Column(
              children: <Widget>[
                Padding(
                  padding: const EdgeInsets.fromLTRB(18, 12, 18, 0),
                  child: Row(
                    children: <Widget>[
                      SizedBox(
                        width: 48,
                        height: 48,
                        child: _PersonaAvatar(
                          visual: visual,
                          selected: true,
                          padding: 2,
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: <Widget>[
                            Text(
                              visual.fullName,
                              overflow: TextOverflow.ellipsis,
                              style: Theme.of(context).textTheme.titleMedium
                                  ?.copyWith(
                                    color: const Color(0xFF2C2434),
                                    fontWeight: FontWeight.w900,
                                  ),
                            ),
                            const SizedBox(height: 3),
                            _StatusPill(status: status, color: phaseColor),
                          ],
                        ),
                      ),
                      _RoundGlyphButton(
                        icon: Icons.person_rounded,
                        color: const Color(0xFF50366F),
                        onTap: () {},
                      ),
                    ],
                  ),
                ),
                Expanded(
                  child: Center(
                    child: _CallPersonaStage(
                      visual: visual,
                      phase: phase,
                      phaseColor: phaseColor,
                      micLevel: micLevel,
                      onTap: onMainButtonTap,
                    ),
                  ),
                ),
                if (liveSubtitleText.trim().isNotEmpty)
                  _LiveAudioCaption(
                    caption: liveSubtitleText,
                    color: phaseColor,
                    activeWordIndex: liveSubtitleActiveWordIndex,
                  ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(26, 0, 26, 18),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: <Widget>[
                      _CallControlButton(
                        icon: canStopAudio
                            ? Icons.volume_off_rounded
                            : phase.icon,
                        color: canStopAudio
                            ? const Color(0xFFDB8D25)
                            : phaseColor,
                        onTap: canStopAudio ? onStopAudio : onMainButtonTap,
                      ),
                      _CallControlButton(
                        icon: Icons.call_end_rounded,
                        color: const Color(0xFFD84A4A),
                        large: true,
                        onTap: onEndCall,
                      ),
                      _CallControlButton(
                        icon: Icons.account_circle_rounded,
                        color: const Color(0xFF2F6F68),
                        onTap: () {},
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _CallPersonaStage extends StatelessWidget {
  const _CallPersonaStage({
    required this.visual,
    required this.phase,
    required this.phaseColor,
    required this.micLevel,
    required this.onTap,
    this.imageAssetOverride,
  });

  final PersonaVisual visual;
  final CallPhase phase;
  final Color phaseColor;
  final double micLevel;
  final VoidCallback onTap;
  final String? imageAssetOverride;

  @override
  Widget build(BuildContext context) {
    final bool listening = phase == CallPhase.listening;
    final bool speaking = phase == CallPhase.speaking;
    final double level = micLevel.clamp(0.0, 1.0);
    final String? overrideAsset = imageAssetOverride;
    final ImageProvider<Object> personaImage = overrideAsset == null
        ? visual.imageProvider(portrait: true)
        : AssetImage(overrideAsset);

    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final Size screenSize = MediaQuery.sizeOf(context);
        final double maxWidth = constraints.maxWidth.isFinite
            ? constraints.maxWidth
            : screenSize.width;
        final double maxHeight = constraints.maxHeight.isFinite
            ? constraints.maxHeight
            : screenSize.height * 0.58;
        const double statusReserve = 58;
        final double cardAreaHeight = math.max(260, maxHeight - statusReserve);
        final double cardWidth = math.min(
          math.min(
            maxWidth * 0.74,
            cardAreaHeight * _personaPortraitAspectRatio,
          ),
          speaking ? 286 : 278,
        );
        final double cardHeight = cardWidth / _personaPortraitAspectRatio;
        final double cardTop = math.max(6, (cardAreaHeight - cardHeight) / 2);
        final double pulseWidth = cardWidth + 34 + (listening ? level * 36 : 0);
        final double pulseHeight =
            cardHeight + 34 + (listening ? level * 42 : 0);
        final double pulseTop = math.max(0, cardTop - 10);
        const BorderRadius pulseRadius = BorderRadius.all(Radius.circular(34));
        const BorderRadius cardRadius = BorderRadius.all(Radius.circular(22));

        return GestureDetector(
          onTap: onTap,
          child: SizedBox.expand(
            child: Stack(
              alignment: Alignment.topCenter,
              children: <Widget>[
                Positioned(
                  top: pulseTop,
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 100),
                    width: pulseWidth,
                    height: pulseHeight,
                    decoration: BoxDecoration(
                      borderRadius: pulseRadius,
                      color: phaseColor.withValues(
                        alpha: listening ? 0.12 + level * 0.14 : 0.08,
                      ),
                      border: Border.all(
                        color: phaseColor.withValues(
                          alpha: listening ? 0.24 + level * 0.28 : 0.14,
                        ),
                        width: listening ? 3 : 2,
                      ),
                    ),
                  ),
                ),
                Positioned(
                  top: cardTop,
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 180),
                    width: cardWidth,
                    height: cardHeight,
                    decoration: BoxDecoration(
                      borderRadius: cardRadius,
                      color: const Color(0xFFFFF6D8).withValues(alpha: 0.94),
                      border: Border.all(
                        color: const Color(0xFFE0A82E),
                        width: 5,
                      ),
                      boxShadow: <BoxShadow>[
                        BoxShadow(
                          color: visual.color.withValues(alpha: 0.28),
                          blurRadius: 28,
                          offset: const Offset(0, 14),
                        ),
                      ],
                    ),
                    clipBehavior: Clip.antiAlias,
                    child: Padding(
                      padding: const EdgeInsets.all(5),
                      child: ClipRRect(
                        borderRadius: const BorderRadius.all(
                          Radius.circular(16),
                        ),
                        child: Image(
                          image: personaImage,
                          fit: BoxFit.cover,
                          alignment: Alignment.center,
                          filterQuality: FilterQuality.high,
                          errorBuilder:
                              (
                                BuildContext context,
                                Object error,
                                StackTrace? stackTrace,
                              ) => Image.asset(
                                visual.assetPath,
                                fit: BoxFit.cover,
                                alignment: Alignment.center,
                              ),
                        ),
                      ),
                    ),
                  ),
                ),
                Positioned(
                  bottom: 8,
                  child: _StatusBubble(phase: phase, color: phaseColor),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _StatusBubble extends StatelessWidget {
  const _StatusBubble({required this.phase, required this.color});

  final CallPhase phase;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 9),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.90),
        borderRadius: BorderRadius.circular(22),
        boxShadow: <BoxShadow>[
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.12),
            blurRadius: 12,
            offset: const Offset(0, 5),
          ),
        ],
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Icon(phase.icon, color: color, size: 18),
          const SizedBox(width: 7),
          Text(
            phase.label,
            style: Theme.of(context).textTheme.labelLarge?.copyWith(
              color: const Color(0xFF2C2434),
              fontWeight: FontWeight.w800,
            ),
          ),
        ],
      ),
    );
  }
}

class _StatusPill extends StatelessWidget {
  const _StatusPill({required this.status, required this.color});

  final String status;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.66),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: color.withValues(alpha: 0.32)),
      ),
      child: Text(
        status,
        overflow: TextOverflow.ellipsis,
        style: Theme.of(context).textTheme.labelSmall?.copyWith(
          color: const Color(0xFF493458),
          fontWeight: FontWeight.w800,
        ),
      ),
    );
  }
}

class _CallControlButton extends StatelessWidget {
  const _CallControlButton({
    required this.icon,
    required this.color,
    required this.onTap,
    this.large = false,
  });

  final IconData icon;
  final Color color;
  final VoidCallback onTap;
  final bool large;

  @override
  Widget build(BuildContext context) {
    final double size = large ? 72 : 58;
    return SizedBox(
      width: size,
      height: size,
      child: IconButton.filled(
        onPressed: onTap,
        style: IconButton.styleFrom(
          backgroundColor: color,
          foregroundColor: Colors.white,
          shadowColor: color.withValues(alpha: 0.42),
          elevation: 8,
        ),
        icon: Icon(icon, size: large ? 34 : 28),
      ),
    );
  }
}

class _LiveAudioCaption extends StatelessWidget {
  const _LiveAudioCaption({
    required this.caption,
    required this.color,
    this.activeWordIndex = -1,
  });

  final String caption;
  final Color color;
  final int activeWordIndex;

  @override
  Widget build(BuildContext context) {
    final bool visible = caption.trim().isNotEmpty;
    final TextStyle baseStyle =
        Theme.of(context).textTheme.titleMedium?.copyWith(
          color: Colors.white,
          fontWeight: FontWeight.w900,
          height: 1.22,
          letterSpacing: 0.05,
        ) ??
        const TextStyle(
          color: Colors.white,
          fontWeight: FontWeight.w900,
          fontSize: 18,
          height: 1.22,
        );
    final TextStyle activeStyle = baseStyle.copyWith(
      color: const Color(0xFFFF4C4C),
      fontWeight: FontWeight.w900,
    );
    return SizedBox(
      height: 108,
      child: AnimatedSwitcher(
        duration: const Duration(milliseconds: 160),
        child: visible
            ? Padding(
                key: const ValueKey<String>('live-audio-caption'),
                padding: const EdgeInsets.fromLTRB(18, 0, 18, 12),
                child: Align(
                  alignment: Alignment.bottomCenter,
                  child: Container(
                    width: double.infinity,
                    constraints: const BoxConstraints(maxWidth: 640),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 13,
                    ),
                    decoration: BoxDecoration(
                      color: const Color(0xFF111018).withValues(alpha: 0.86),
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(color: color.withValues(alpha: 0.30)),
                      boxShadow: <BoxShadow>[
                        BoxShadow(
                          color: Colors.black.withValues(alpha: 0.24),
                          blurRadius: 18,
                          offset: const Offset(0, 8),
                        ),
                      ],
                    ),
                    child: RichText(
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      textAlign: TextAlign.center,
                      text: TextSpan(
                        children: _captionSpans(
                          caption,
                          baseStyle: baseStyle,
                          activeStyle: activeStyle,
                          activeWordIndex: activeWordIndex,
                        ),
                      ),
                    ),
                  ),
                ),
              )
            : const SizedBox(key: ValueKey<String>('live-audio-caption-empty')),
      ),
    );
  }

  List<TextSpan> _captionSpans(
    String value, {
    required TextStyle baseStyle,
    required TextStyle activeStyle,
    required int activeWordIndex,
  }) {
    final List<TextSpan> spans = <TextSpan>[];
    var wordIndex = 0;
    for (final Match match in RegExp(r'\S+|\s+').allMatches(value)) {
      final String token = match.group(0) ?? '';
      if (token.trim().isEmpty) {
        spans.add(TextSpan(text: token, style: baseStyle));
        continue;
      }
      final bool active = wordIndex == activeWordIndex;
      spans.add(TextSpan(text: token, style: active ? activeStyle : baseStyle));
      wordIndex += 1;
    }
    if (spans.isEmpty) {
      spans.add(TextSpan(text: value, style: baseStyle));
    }
    return spans;
  }
}

class _RoundGlyphButton extends StatelessWidget {
  const _RoundGlyphButton({
    required this.icon,
    required this.color,
    required this.onTap,
  });

  final IconData icon;
  final Color color;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 48,
      height: 48,
      child: IconButton.filledTonal(
        onPressed: onTap,
        style: IconButton.styleFrom(
          backgroundColor: Colors.white.withValues(alpha: 0.78),
          foregroundColor: color,
          side: BorderSide(color: color.withValues(alpha: 0.30), width: 1.5),
        ),
        icon: Icon(icon),
      ),
    );
  }
}

// ignore: unused_element
class _WheelPersonaSprite extends StatelessWidget {
  const _WheelPersonaSprite({
    required this.visual,
    required this.selected,
    required this.size,
  });

  final PersonaVisual visual;
  final bool selected;
  final double size;

  @override
  Widget build(BuildContext context) {
    return Stack(
      clipBehavior: Clip.none,
      alignment: Alignment.center,
      children: <Widget>[
        AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          width: size * (selected ? 0.72 : 0.58),
          height: size * (selected ? 0.72 : 0.58),
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: visual.color.withValues(alpha: selected ? 0.18 : 0.08),
            boxShadow: <BoxShadow>[
              BoxShadow(
                color: visual.color.withValues(alpha: selected ? 0.42 : 0.18),
                blurRadius: selected ? 20 : 12,
                spreadRadius: selected ? 2 : 0,
              ),
            ],
          ),
        ),
        Positioned.fill(
          child: Image.asset(
            visual.assetPath,
            fit: BoxFit.contain,
            filterQuality: FilterQuality.high,
          ),
        ),
      ],
    );
  }
}

class _PersonaAvatar extends StatelessWidget {
  const _PersonaAvatar({
    required this.visual,
    required this.selected,
    required this.padding,
  });

  final PersonaVisual visual;
  final bool selected;
  final double padding;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: Colors.white.withValues(alpha: 0.78),
        border: Border.all(
          color: selected ? const Color(0xFFF7C948) : Colors.white,
          width: selected ? 3 : 2,
        ),
        boxShadow: <BoxShadow>[
          BoxShadow(
            color: visual.color.withValues(alpha: selected ? 0.34 : 0.18),
            blurRadius: selected ? 16 : 8,
            offset: const Offset(0, 5),
          ),
        ],
      ),
      child: Padding(
        padding: EdgeInsets.all(padding),
        child: ClipOval(
          child: Padding(
            padding: const EdgeInsets.all(2),
            child: Image(
              image: visual.imageProvider(portrait: true),
              fit: BoxFit.contain,
              errorBuilder:
                  (
                    BuildContext context,
                    Object error,
                    StackTrace? stackTrace,
                  ) => Image.asset(visual.assetPath, fit: BoxFit.contain),
            ),
          ),
        ),
      ),
    );
  }
}

// ignore: unused_element
class _DeveloperTray extends StatelessWidget {
  const _DeveloperTray({
    required this.phaseColor,
    required this.status,
    required this.persona,
    required this.eventCount,
    required this.micBytes,
    required this.micFrames,
    required this.nativeMicBytes,
    required this.nativeMicFrames,
    required this.nativeAudioSource,
    required this.nativeVadSource,
    required this.nativeVadMode,
    required this.audioBytes,
    required this.transcriptController,
    required this.userText,
    required this.assistantText,
    required this.metrics,
    required this.events,
    required this.textController,
    required this.textEnabled,
    required this.onSendText,
    required this.onTestAudio,
  });

  final Color phaseColor;
  final String status;
  final String persona;
  final int eventCount;
  final int micBytes;
  final int micFrames;
  final int nativeMicBytes;
  final int nativeMicFrames;
  final String nativeAudioSource;
  final String nativeVadSource;
  final String nativeVadMode;
  final int audioBytes;
  final ScrollController transcriptController;
  final String userText;
  final String assistantText;
  final Map<String, Object?> metrics;
  final List<String> events;
  final TextEditingController textController;
  final bool textEnabled;
  final VoidCallback onSendText;
  final VoidCallback onTestAudio;

  @override
  Widget build(BuildContext context) {
    return Theme(
      data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(10, 0, 10, 10),
        child: Material(
          color: Colors.white.withValues(alpha: 0.84),
          borderRadius: BorderRadius.circular(14),
          clipBehavior: Clip.antiAlias,
          child: ExpansionTile(
            tilePadding: const EdgeInsets.symmetric(horizontal: 14),
            childrenPadding: const EdgeInsets.fromLTRB(10, 0, 10, 10),
            leading: const Icon(Icons.tune_rounded),
            title: const Text(
              'Diagnostics',
              style: TextStyle(fontWeight: FontWeight.w800),
            ),
            children: <Widget>[
              ConstrainedBox(
                constraints: BoxConstraints(
                  maxHeight: MediaQuery.sizeOf(context).height * 0.62,
                ),
                child: SingleChildScrollView(
                  child: Column(
                    children: <Widget>[
                      Row(
                        children: <Widget>[
                          Expanded(
                            child: FilledButton.icon(
                              onPressed: () => _showDiagnosticTextSheet(
                                context,
                                metrics,
                                title: 'Talk Trace',
                              ),
                              icon: const Icon(Icons.article_rounded),
                              label: const Text('Open All'),
                            ),
                          ),
                          const SizedBox(width: 10),
                          FilledButton.icon(
                            onPressed: onTestAudio,
                            icon: const Icon(Icons.volume_up_rounded),
                            label: const Text('Test Audio'),
                          ),
                        ],
                      ),
                      const SizedBox(height: 10),
                      _FocusedTracePanel(metrics: metrics),
                      const SizedBox(height: 10),
                      _TextFallbackBar(
                        controller: textController,
                        enabled: textEnabled,
                        onSend: onSendText,
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _DiagnosticTraceEntry {
  const _DiagnosticTraceEntry({
    required this.key,
    required this.title,
    required this.icon,
    required this.value,
  });

  final String key;
  final String title;
  final IconData icon;
  final String value;
}

class _FocusedTracePanel extends StatelessWidget {
  const _FocusedTracePanel({required this.metrics});

  final Map<String, Object?> metrics;

  @override
  Widget build(BuildContext context) {
    final List<_DiagnosticTraceEntry> entries = _focusedDiagnosticEntries(
      metrics,
    );
    return Column(
      children: entries
          .map(
            (_DiagnosticTraceEntry entry) => Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: _FocusedTraceCard(entry: entry, metrics: metrics),
            ),
          )
          .toList(),
    );
  }
}

class _FocusedTraceCard extends StatelessWidget {
  const _FocusedTraceCard({required this.entry, required this.metrics});

  final _DiagnosticTraceEntry entry;
  final Map<String, Object?> metrics;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.white,
      borderRadius: BorderRadius.circular(8),
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: () => _showDiagnosticTextSheet(
          context,
          metrics,
          title: entry.title,
          focusKey: entry.key,
        ),
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: const Color(0xFFE3E7ED)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Row(
                children: <Widget>[
                  Icon(entry.icon, size: 18, color: const Color(0xFF516070)),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      entry.title,
                      style: Theme.of(context).textTheme.labelLarge?.copyWith(
                        color: const Color(0xFF202A35),
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                  ),
                  const Icon(
                    Icons.open_in_full_rounded,
                    size: 16,
                    color: Color(0xFF516070),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              SelectableText(
                _compactDiagnosticText(
                  entry.value,
                  limit: _diagnosticCardTextMaxChars,
                ),
                maxLines: 7,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: const Color(0xFF202A35),
                  height: 1.28,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

List<_DiagnosticTraceEntry> _focusedDiagnosticEntries(
  Map<String, Object?> metrics,
) {
  return <_DiagnosticTraceEntry>[
    _DiagnosticTraceEntry(
      key: 'pocket_tts_spoken_chunks',
      title: 'PocketTTS Input Chunks',
      icon: Icons.record_voice_over_rounded,
      value: _firstMetricText(metrics, <String>[
        'pocket_tts_spoken_chunks',
        'pocket_tts_input',
      ], 'Waiting for PocketTTS input...'),
    ),
    _DiagnosticTraceEntry(
      key: 'whisper_asr_output',
      title: 'User Whisper Data',
      icon: Icons.hearing_rounded,
      value: _firstMetricText(metrics, <String>[
        'whisper_asr_output',
        'asr_transcript',
      ], 'Waiting for user speech...'),
    ),
    _DiagnosticTraceEntry(
      key: 'llm_stream_full_response',
      title: 'LLM Output',
      icon: Icons.auto_awesome_rounded,
      value: _firstMetricText(metrics, <String>[
        'llm_stream_full_response',
      ], 'Waiting for LLM output...'),
    ),
    _DiagnosticTraceEntry(
      key: 'pocket_tts_queued_chunks',
      title: 'LLM Output To PocketTTS Chunks',
      icon: Icons.segment_rounded,
      value: _firstMetricText(metrics, <String>[
        'pocket_tts_queued_chunks',
      ], 'Waiting for chunked LLM text...'),
    ),
  ];
}

String _firstMetricText(
  Map<String, Object?> metrics,
  List<String> keys,
  String fallback,
) {
  for (final String key in keys) {
    final String value = '${metrics[key] ?? ''}'.trim();
    if (value.isNotEmpty) {
      return _compactDiagnosticText(value, limit: _diagnosticSheetTextMaxChars);
    }
  }
  return fallback;
}

void _showDiagnosticTextSheet(
  BuildContext context,
  Map<String, Object?> metrics, {
  String title = 'Diagnostics Text',
  String? focusKey,
}) {
  final List<_DiagnosticTraceEntry> entries = _focusedDiagnosticEntries(metrics)
      .where(
        (_DiagnosticTraceEntry entry) =>
            focusKey == null || entry.key == focusKey,
      )
      .toList();

  showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    backgroundColor: Colors.white,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
    ),
    builder: (BuildContext sheetContext) {
      return DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.92,
        minChildSize: 0.45,
        maxChildSize: 0.96,
        builder: (BuildContext context, ScrollController scrollController) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 8, 8),
                child: Row(
                  children: <Widget>[
                    Expanded(
                      child: Text(
                        focusKey ?? title,
                        style: Theme.of(context).textTheme.titleMedium
                            ?.copyWith(
                              color: const Color(0xFF202A35),
                              fontWeight: FontWeight.w900,
                            ),
                      ),
                    ),
                    IconButton(
                      onPressed: () => Navigator.of(sheetContext).pop(),
                      icon: const Icon(Icons.close_rounded),
                    ),
                  ],
                ),
              ),
              const Divider(height: 1),
              Expanded(
                child: entries.isEmpty
                    ? Center(
                        child: Text(
                          'No text trace yet',
                          style: Theme.of(context).textTheme.bodyMedium
                              ?.copyWith(color: const Color(0xFF516070)),
                        ),
                      )
                    : ListView.separated(
                        controller: scrollController,
                        padding: const EdgeInsets.all(14),
                        itemCount: entries.length,
                        separatorBuilder: (BuildContext context, int index) =>
                            const SizedBox(height: 12),
                        itemBuilder: (BuildContext context, int index) {
                          final _DiagnosticTraceEntry entry = entries[index];
                          return _DiagnosticTextBlock(
                            name: entry.title,
                            value: _compactDiagnosticText(
                              entry.value,
                              limit: _diagnosticSheetTextMaxChars,
                            ),
                          );
                        },
                      ),
              ),
            ],
          );
        },
      );
    },
  );
}

class _DiagnosticTextBlock extends StatelessWidget {
  const _DiagnosticTextBlock({required this.name, required this.value});

  final String name;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFFF6F8FA),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: const Color(0xFFE3E7ED)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            name,
            style: Theme.of(context).textTheme.labelLarge?.copyWith(
              color: const Color(0xFF516070),
              fontWeight: FontWeight.w900,
            ),
          ),
          const SizedBox(height: 8),
          SelectableText(
            _compactDiagnosticText(value, limit: _diagnosticSheetTextMaxChars),
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: const Color(0xFF202A35),
              height: 1.32,
            ),
          ),
        ],
      ),
    );
  }
}

String _compactDiagnosticText(String text, {required int limit}) {
  if (text.length <= limit) {
    return text;
  }
  final int headChars = math.max(0, math.min(220, limit ~/ 4));
  final int tailChars = math.max(0, limit - headChars - 48);
  final String head = text.substring(0, headChars).trimRight();
  final String tail = text.substring(text.length - tailChars).trimLeft();
  return '$head\n\n[trimmed ${text.length - headChars - tailChars} chars]\n\n$tail';
}

class _TextFallbackBar extends StatelessWidget {
  const _TextFallbackBar({
    required this.controller,
    required this.enabled,
    required this.onSend,
  });

  final TextEditingController controller;
  final bool enabled;
  final VoidCallback onSend;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 10, 14, 14),
      decoration: const BoxDecoration(
        color: Colors.white,
        border: Border(top: BorderSide(color: Color(0xFFE3E7ED))),
      ),
      child: Row(
        children: <Widget>[
          Expanded(
            child: TextField(
              controller: controller,
              enabled: enabled,
              minLines: 1,
              maxLines: 3,
              textInputAction: TextInputAction.send,
              onSubmitted: (_) => onSend(),
              decoration: const InputDecoration(
                hintText: 'Type a turn',
                prefixIcon: Icon(Icons.keyboard),
                border: OutlineInputBorder(),
                isDense: true,
              ),
            ),
          ),
          const SizedBox(width: 10),
          IconButton.filled(
            onPressed: enabled ? onSend : null,
            icon: const Icon(Icons.send),
          ),
        ],
      ),
    );
  }
}
