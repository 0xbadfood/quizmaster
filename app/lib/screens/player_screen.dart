import 'dart:async';
import 'dart:io';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:provider/provider.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../data/deployed_content_repository.dart';
import '../data/generated_bundle_loader.dart';
import '../models/content_item.dart';
import '../models/playlist.dart';
import '../models/player_bundle.dart';
import '../models/scene.dart';
import '../providers/app_state.dart';
import '../theme/app_theme.dart';
import '../utils/user_facing_error.dart';
import '../widgets/add_to_playlist_sheet.dart';
import '../widgets/content_image.dart';
import '../widgets/scene_thumbnail.dart';
import 'story_quiz_screen.dart';

const ContentItem _emptyPlaybackItem = ContentItem(
  id: 'unavailable_content',
  type: 'story',
  language: 'english',
  title: 'Content Not Available',
  category: '',
  duration: '00:00',
  durationSeconds: 0,
  thumbnail: 'assets/images/app_icon.png',
  audioSrc: '',
);

class PlayerScreen extends StatefulWidget {
  final ContentItem? item;
  final PlaylistPlaybackContext? playlistContext;
  final bool autoplay;
  final VoidCallback? onBack;
  const PlayerScreen({
    super.key,
    this.item,
    this.playlistContext,
    this.autoplay = false,
    this.onBack,
  });

  @override
  State<PlayerScreen> createState() => _PlayerScreenState();
}

class _PlayerScreenState extends State<PlayerScreen> {
  final AudioPlayer _audioPlayer = AudioPlayer();
  static const int _transcriptTargetChars = 64;

  bool _playing = false;
  bool _lyricsOn = true;
  double _currentTime = 0.0;
  double _currentDurationSeconds = 0.0;
  bool _bundleLoading = false;
  bool _playlistTransitioning = false;
  String? _bundleError;
  PlayerBundle? _bundle;
  bool _didComplete = false;
  int _lastSavedSecond = -1;
  ContentItem? _playbackRegisteredItem;
  StreamSubscription<Duration>? _positionSubscription;
  StreamSubscription<Duration>? _durationSubscription;
  StreamSubscription<void>? _completeSubscription;

  ContentItem get _fallbackItem => widget.item ?? _emptyPlaybackItem;
  PlaylistPlaybackContext? get _playlistContext => widget.playlistContext;
  ContentItem get _item => _bundle?.content ?? _fallbackItem;
  Playlist? get _playlist => _playlistContext == null
      ? null
      : context.read<AppState>().getPlaylistById(_playlistContext!.playlistId);
  List<Scene> get _scenes =>
      _bundle?.scenes.isNotEmpty == true ? _bundle!.scenes : _fallbackScenes;
  List<TranscriptWord> get _transcript =>
      _bundle?.transcriptWords.isNotEmpty == true
      ? _bundle!.transcriptWords
      : const [];
  String get _currentAudioPath =>
      (_bundle?.content.audioSrc ?? _fallbackItem.audioSrc).trim();
  double get _maxDurationSeconds {
    final bundleOrItemDuration = _item.durationSeconds.toDouble();
    if (_currentDurationSeconds > 0) {
      return _currentDurationSeconds;
    }
    return bundleOrItemDuration > 0 ? bundleOrItemDuration : 1.0;
  }

  @override
  void initState() {
    super.initState();
    WakelockPlus.enable();
    _bindAudioListeners();
    _loadPlayableContent(autoPlay: widget.autoplay);
  }

  @override
  void didUpdateWidget(covariant PlayerScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.item?.id != widget.item?.id ||
        oldWidget.playlistContext?.playlistId !=
            widget.playlistContext?.playlistId ||
        oldWidget.playlistContext?.itemIndex !=
            widget.playlistContext?.itemIndex ||
        oldWidget.autoplay != widget.autoplay) {
      _loadPlayableContent(autoPlay: widget.autoplay);
    }
  }

  @override
  void dispose() {
    final currentItem = _playbackRegisteredItem;
    if (currentItem != null) {
      unawaited(
        DeployedContentRepository.instance.markPlaybackStopped(currentItem),
      );
      _playbackRegisteredItem = null;
    }
    _positionSubscription?.cancel();
    _durationSubscription?.cancel();
    _completeSubscription?.cancel();
    _audioPlayer.dispose();
    WakelockPlus.disable();
    super.dispose();
  }

  void _bindAudioListeners() {
    _positionSubscription = _audioPlayer.onPositionChanged.listen((position) {
      if (!mounted) {
        return;
      }
      final nextSeconds = position.inMilliseconds / 1000.0;
      setState(() {
        _currentTime = nextSeconds;
        _didComplete = false;
      });
      _persistPlaybackProgress(throttle: true);
    });
    _durationSubscription = _audioPlayer.onDurationChanged.listen((duration) {
      if (!mounted) {
        return;
      }
      setState(() {
        _currentDurationSeconds = duration.inMilliseconds / 1000.0;
      });
    });
    _completeSubscription = _audioPlayer.onPlayerComplete.listen((_) {
      if (!mounted) {
        return;
      }
      setState(() {
        _playing = false;
        _didComplete = true;
        _currentTime = _currentDurationSeconds > 0
            ? _currentDurationSeconds
            : _maxDurationSeconds;
      });
      _audioPlayer.seek(Duration.zero);
      _persistPlaybackProgress(resetToStart: true);
      final completedItem = _playbackRegisteredItem;
      if (completedItem != null) {
        _playbackRegisteredItem = null;
        unawaited(_handlePlaybackCompleted(completedItem));
      }
    });
  }

  Future<void> _handlePlaybackCompleted(ContentItem completedItem) async {
    await DeployedContentRepository.instance.markPlaybackCompleted(
      completedItem,
    );
    if (!mounted) {
      return;
    }
    await _maybeOfferStoryQuiz(completedItem);
    if (!mounted) {
      return;
    }
    final nextContext = _playlistContext == null
        ? null
        : context.read<AppState>().nextPlaylistContext(_playlistContext!);
    if (nextContext != null) {
      await _openPlaylistContext(nextContext, autoplay: true);
      return;
    }
    await _loadPlayableContent();
  }

  Future<void> _maybeOfferStoryQuiz(ContentItem completedItem) async {
    final quiz = _bundle?.quiz;
    final appState = context.read<AppState>();
    if (completedItem.type.toLowerCase() != 'story' ||
        quiz == null ||
        !quiz.hasQuestions ||
        !appState.quizEnabled ||
        appState.hasQuizAttempt(completedItem)) {
      return;
    }

    final takeQuiz = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) {
        return AlertDialog(
          backgroundColor: SunshineColors.cream,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(28),
          ),
          title: Row(
            children: [
              Container(
                width: 42,
                height: 42,
                decoration: const BoxDecoration(
                  gradient: SunshineColors.pinkGradient,
                  shape: BoxShape.circle,
                ),
                child: const Icon(
                  Icons.quiz,
                  color: SunshineColors.white,
                  size: 22,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  'Ready for a quiz?',
                  style: GoogleFonts.nunito(
                    fontSize: 21,
                    fontWeight: FontWeight.w900,
                    color: SunshineColors.darkText,
                  ),
                ),
              ),
            ],
          ),
          content: Text(
            'Answer a few questions from "${completedItem.displayTitle}". Only your first completed score is saved.',
            style: GoogleFonts.nunito(
              fontSize: 14,
              fontWeight: FontWeight.w700,
              color: SunshineColors.darkText.withValues(alpha: 0.72),
            ),
          ),
          actionsPadding: const EdgeInsets.fromLTRB(20, 0, 20, 18),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: Text(
                'Maybe Later',
                style: GoogleFonts.nunito(fontWeight: FontWeight.w800),
              ),
            ),
            ElevatedButton(
              onPressed: () => Navigator.of(dialogContext).pop(true),
              child: const Text('Take Quiz'),
            ),
          ],
        );
      },
    );

    if (!mounted || takeQuiz != true) {
      return;
    }
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => StoryQuizScreen(item: completedItem, quiz: quiz),
      ),
    );
  }

  Future<void> _loadPlayableContent({bool autoPlay = false}) async {
    final appState = context.read<AppState>();
    final previousItem = _playbackRegisteredItem;
    if (previousItem != null) {
      await DeployedContentRepository.instance.markPlaybackStopped(
        previousItem,
      );
      _playbackRegisteredItem = null;
    }
    setState(() {
      _playing = false;
      _currentTime = 0.0;
      _currentDurationSeconds = 0.0;
      _bundleLoading = true;
      _playlistTransitioning = false;
      _bundleError = null;
      _bundle = null;
      _didComplete = false;
    });
    await _audioPlayer.stop();

    try {
      var playableFallback = _fallbackItem;
      final needsDownload =
          (playableFallback.bundleUrl ?? '').trim().isNotEmpty &&
          ((playableFallback.bundleFilePath ??
                      playableFallback.bundleAssetPath ??
                      '')
                  .trim())
              .isEmpty;
      if (needsDownload) {
        playableFallback = await DeployedContentRepository.instance
            .ensureDownloaded(playableFallback);
      }
      final playableBundlePath =
          playableFallback.bundleFilePath ?? playableFallback.bundleAssetPath;
      final bundle = await GeneratedBundleLoader.load(playableBundlePath);
      final nextBundle = bundle;
      final nextItem = nextBundle?.content ?? playableFallback;
      if (nextItem.audioSrc.trim().isNotEmpty) {
        await _audioPlayer.setSource(_audioSourceFor(nextItem.audioSrc));
      }
      final resumeSeconds = appState.resumePositionFor(
        nextItem,
        playlistContext: _playlistContext,
      );
      if (resumeSeconds > 0 && nextItem.audioSrc.trim().isNotEmpty) {
        await _audioPlayer.seek(
          Duration(milliseconds: (resumeSeconds * 1000).round()),
        );
      }
      if (autoPlay && nextItem.audioSrc.trim().isNotEmpty) {
        await _audioPlayer.resume();
      }
      if (!mounted) {
        return;
      }
      DeployedContentRepository.instance.markPlaybackStarted(nextItem);
      setState(() {
        _bundle = nextBundle;
        _bundleLoading = false;
        _currentTime = resumeSeconds;
        _playing = autoPlay;
      });
      _playbackRegisteredItem = nextItem;
      _prefetchNextPlaylistItem();
    } catch (error) {
      try {
        if (_fallbackItem.audioSrc.trim().isNotEmpty) {
          await _audioPlayer.setSource(_audioSourceFor(_fallbackItem.audioSrc));
        }
        final resumeSeconds = appState.resumePositionFor(
          _fallbackItem,
          playlistContext: _playlistContext,
        );
        if (resumeSeconds > 0 && _fallbackItem.audioSrc.trim().isNotEmpty) {
          await _audioPlayer.seek(
            Duration(milliseconds: (resumeSeconds * 1000).round()),
          );
        }
        if (autoPlay && _fallbackItem.audioSrc.trim().isNotEmpty) {
          await _audioPlayer.resume();
        }
      } catch (_) {
        // ignore fallback setSource failure
      }
      if (!mounted) {
        return;
      }
      DeployedContentRepository.instance.markPlaybackStarted(_fallbackItem);
      setState(() {
        _bundleLoading = false;
        _bundleError = friendlyContentLoadMessage(error, 'this item');
        _playing = autoPlay;
      });
      _playbackRegisteredItem = _fallbackItem;
    }
  }

  String _normalizeAudioAssetPath(String assetPath) {
    final normalized = assetPath.trim();
    if (normalized.startsWith('assets/')) {
      return normalized.substring('assets/'.length);
    }
    return normalized;
  }

  Source _audioSourceFor(String path) {
    final normalized = path.trim();
    if (normalized.startsWith('/') && File(normalized).existsSync()) {
      return DeviceFileSource(normalized);
    }
    return AssetSource(_normalizeAudioAssetPath(normalized));
  }

  Future<void> _prefetchNextPlaylistItem() async {
    final playlistContext = _playlistContext;
    if (playlistContext == null) {
      return;
    }
    final nextContext = context.read<AppState>().nextPlaylistContext(
      playlistContext,
    );
    if (nextContext == null) {
      return;
    }
    final nextItem = context
        .read<AppState>()
        .playlistItemAt(nextContext.playlistId, nextContext.itemIndex)
        ?.content;
    if (nextItem == null || (nextItem.bundleUrl ?? '').isEmpty) {
      return;
    }
    unawaited(
      DeployedContentRepository.instance
          .ensureDownloaded(nextItem)
          .catchError((_) => nextItem),
    );
  }

  Future<void> _openPlaylistContext(
    PlaylistPlaybackContext playlistContext, {
    bool autoplay = false,
  }) async {
    final navigator = Navigator.of(context);
    final appState = context.read<AppState>();
    final nextItem = appState
        .playlistItemAt(playlistContext.playlistId, playlistContext.itemIndex)
        ?.content;
    if (nextItem == null) {
      return;
    }
    setState(() {
      _playlistTransitioning = true;
      _playing = false;
    });
    ContentItem playableItem = nextItem;
    if ((nextItem.bundleUrl ?? '').isNotEmpty) {
      try {
        playableItem = await DeployedContentRepository.instance
            .ensureDownloaded(nextItem);
      } catch (error) {
        if (!mounted) {
          return;
        }
        setState(() => _playlistTransitioning = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(friendlyContentLoadMessage(error, 'this item')),
          ),
        );
        return;
      }
    }
    if (!mounted) {
      return;
    }
    navigator.pushReplacement(
      MaterialPageRoute(
        builder: (_) => PlayerScreen(
          item: playableItem,
          playlistContext: playlistContext,
          autoplay: autoplay,
          onBack: widget.onBack,
        ),
      ),
    );
  }

  Future<void> _goToNextPlaylistItem() async {
    final playlistContext = _playlistContext;
    if (playlistContext == null) {
      await _seekTo(_maxDurationSeconds);
      return;
    }
    final nextContext = context.read<AppState>().nextPlaylistContext(
      playlistContext,
    );
    if (nextContext == null) {
      await _seekTo(_maxDurationSeconds);
      return;
    }
    await _persistPlaybackProgress(resetToStart: true);
    await _openPlaylistContext(nextContext, autoplay: true);
  }

  Future<void> _goToPreviousPlaylistItem() async {
    final playlistContext = _playlistContext;
    if (playlistContext == null) {
      await _seekTo(0);
      return;
    }
    if (_currentTime > 5.0) {
      await _seekTo(0);
      return;
    }
    final previousContext = context.read<AppState>().previousPlaylistContext(
      playlistContext,
    );
    if (previousContext == null) {
      await _seekTo(0);
      return;
    }
    await _persistPlaybackProgress(resetToStart: true);
    await _openPlaylistContext(previousContext);
  }

  Scene get _currentScene {
    final scenes = _scenes;
    if (scenes.isEmpty) {
      return Scene(
        id: 'scene_fallback',
        number: 1,
        start: 0,
        end: 1,
        image: _fallbackVisualImage,
        label: 'Scene',
      );
    }
    for (final scene in scenes) {
      if (_currentTime >= scene.start && _currentTime < scene.end) {
        return scene;
      }
    }
    if (_currentTime >= scenes.last.end) {
      return scenes.last;
    }
    return scenes.first;
  }

  List<_TranscriptDisplayLine> get _visibleTranscriptLines {
    if (_item.type == 'story') {
      return _visibleStoryTranscriptWindow;
    }
    if (_item.type == 'rhyme') {
      return _visibleRhymeTranscriptWindow;
    }
    return const [];
  }

  List<_TranscriptDisplayLine> get _visibleStoryTranscriptWindow {
    if (_transcript.isEmpty) {
      return const [];
    }

    final chunks = _storyTranscriptChunks;
    if (chunks.isEmpty) {
      return const [];
    }

    final activeWord = _activeTranscriptWord;
    final activeIndex = activeWord != null
        ? _transcript.indexOf(activeWord)
        : 0;
    final safeActiveIndex = activeIndex >= 0 ? activeIndex : 0;

    for (final chunk in chunks) {
      if (safeActiveIndex >= chunk.startIndex &&
          safeActiveIndex <= chunk.endIndex) {
        return [
          _TranscriptDisplayLine(
            lineNumber: chunk.words.first.line,
            words: chunk.words,
            truncated: chunk.endIndex < _transcript.length - 1,
          ),
        ];
      }
    }

    final lastChunk = chunks.last;
    return [
      _TranscriptDisplayLine(
        lineNumber: lastChunk.words.first.line,
        words: lastChunk.words,
        truncated: false,
      ),
    ];
  }

  List<_StoryTranscriptChunk> get _storyTranscriptChunks {
    if (_transcript.isEmpty) {
      return const [];
    }

    final chunks = <_StoryTranscriptChunk>[];
    var startIndex = 0;
    while (startIndex < _transcript.length) {
      final selectedWords = <TranscriptWord>[];
      var usedChars = 0;
      var endIndex = startIndex;

      for (var index = startIndex; index < _transcript.length; index++) {
        final word = _transcript[index];
        final addition = (selectedWords.isEmpty ? 0 : 1) + word.word.length;
        if (selectedWords.isNotEmpty &&
            usedChars + addition > _transcriptTargetChars) {
          break;
        }
        selectedWords.add(word);
        usedChars += addition;
        endIndex = index;
      }

      if (selectedWords.isEmpty) {
        selectedWords.add(_transcript[startIndex]);
        endIndex = startIndex;
      }

      chunks.add(
        _StoryTranscriptChunk(
          startIndex: startIndex,
          endIndex: endIndex,
          words: selectedWords,
        ),
      );
      startIndex = endIndex + 1;
    }

    return chunks;
  }

  List<_TranscriptDisplayLine> get _visibleRhymeTranscriptWindow {
    if (_transcript.isEmpty) {
      return const [];
    }

    final wordsByLine = <int, List<TranscriptWord>>{};
    final orderedLineNumbers = <int>[];
    for (final word in _transcript) {
      final lineNumber = word.line;
      if (!wordsByLine.containsKey(lineNumber)) {
        wordsByLine[lineNumber] = <TranscriptWord>[];
        orderedLineNumbers.add(lineNumber);
      }
      wordsByLine[lineNumber]!.add(word);
    }
    if (orderedLineNumbers.isEmpty) {
      return const [];
    }

    final activeWord = _activeTranscriptWord;
    var activeLineIndex = activeWord == null
        ? -1
        : orderedLineNumbers.indexOf(activeWord.line);
    if (activeLineIndex < 0) {
      activeLineIndex = 0;
      for (var index = 0; index < orderedLineNumbers.length; index++) {
        final lineWords = wordsByLine[orderedLineNumbers[index]] ?? const [];
        if (lineWords.isEmpty) {
          continue;
        }
        final lineEnd = lineWords.last.end;
        if (_currentTime <= lineEnd) {
          activeLineIndex = index;
          break;
        }
      }
    }

    final selectedLineNumbers = <int>[orderedLineNumbers[activeLineIndex]];
    final nextLineIndex = activeLineIndex + 1;
    if (nextLineIndex < orderedLineNumbers.length) {
      selectedLineNumbers.add(orderedLineNumbers[nextLineIndex]);
    }

    return selectedLineNumbers
        .map(
          (lineNumber) => _TranscriptDisplayLine(
            lineNumber: lineNumber,
            words: wordsByLine[lineNumber] ?? const [],
            truncated: false,
          ),
        )
        .where((line) => line.words.isNotEmpty)
        .toList();
  }

  TranscriptWord? get _activeTranscriptWord {
    if (_transcript.isEmpty) {
      return null;
    }
    for (var index = 0; index < _transcript.length; index++) {
      final word = _transcript[index];
      if (_currentTime >= word.start && _currentTime <= word.end) {
        var runStart = index;
        var runEnd = index;
        while (runStart > 0 &&
            _transcript[runStart - 1].start == word.start &&
            _transcript[runStart - 1].end == word.end) {
          runStart -= 1;
        }
        while (runEnd + 1 < _transcript.length &&
            _transcript[runEnd + 1].start == word.start &&
            _transcript[runEnd + 1].end == word.end) {
          runEnd += 1;
        }
        if (runEnd > runStart && word.end > word.start) {
          final runLength = runEnd - runStart + 1;
          final progress =
              ((_currentTime - word.start) / (word.end - word.start)).clamp(
                0.0,
                0.999999,
              );
          final offset = (progress * runLength).floor().clamp(0, runLength - 1);
          return _transcript[runStart + offset];
        }
        return word;
      }
    }
    for (final word in _transcript) {
      if (_currentTime < word.start) {
        return word;
      }
    }
    return _transcript.isNotEmpty ? _transcript.last : null;
  }

  Future<void> _togglePlay() async {
    if (_currentAudioPath.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Audio is not available for this item yet.'),
        ),
      );
      return;
    }
    if (_playing) {
      await _audioPlayer.pause();
      await _persistPlaybackProgress();
      if (!mounted) {
        return;
      }
      setState(() => _playing = false);
      return;
    }

    if (_didComplete || _currentTime >= _maxDurationSeconds - 0.05) {
      await _audioPlayer.play(
        _audioSourceFor(_currentAudioPath),
        position: Duration.zero,
      );
      if (mounted) {
        setState(() {
          _currentTime = 0.0;
          _didComplete = false;
        });
      }
    } else {
      await _audioPlayer.resume();
    }
    if (!mounted) {
      return;
    }
    setState(() => _playing = true);
    _persistPlaybackProgress();
  }

  Future<void> _seekTo(double time) async {
    final clamped = time.clamp(0, _maxDurationSeconds).toDouble();
    await _audioPlayer.seek(Duration(milliseconds: (clamped * 1000).round()));
    if (!mounted) {
      return;
    }
    setState(() {
      _currentTime = clamped;
      _didComplete = false;
    });
    await _persistPlaybackProgress();
  }

  Future<void> _persistPlaybackProgress({
    bool throttle = false,
    bool resetToStart = false,
  }) async {
    if (!mounted) {
      return;
    }
    final appState = context.read<AppState>();
    final secondBucket = _currentTime.floor();
    if (throttle && secondBucket == _lastSavedSecond) {
      return;
    }
    if (throttle && secondBucket % 5 != 0) {
      return;
    }
    _lastSavedSecond = secondBucket;
    final item = _item;
    final duration = _currentDurationSeconds > 0
        ? _currentDurationSeconds
        : item.durationSeconds.toDouble();
    await appState.updateLastPlayed(
      item,
      positionSeconds: resetToStart ? 0.0 : _currentTime,
      durationSeconds: duration,
      playlistContext: _playlistContext,
    );
  }

  String _formatTime(double seconds) {
    final value = seconds.isFinite ? seconds : 0.0;
    final minutes = value ~/ 60;
    final secs = (value % 60).toInt();
    return '${minutes.toString().padLeft(2, '0')}:${secs.toString().padLeft(2, '0')}';
  }

  String get _fallbackVisualImage {
    final thumbnail = _item.thumbnail.trim();
    if (thumbnail.isNotEmpty) {
      return thumbnail;
    }
    final thumbnailUrl = (_item.thumbnailUrl ?? '').trim();
    if (thumbnailUrl.isNotEmpty) {
      return thumbnailUrl;
    }
    return 'assets/images/app_icon.png';
  }

  List<Scene> get _fallbackScenes => [
    Scene(
      id: 'scene_fallback',
      number: 1,
      start: 0,
      end: _maxDurationSeconds > 1 ? _maxDurationSeconds : 1,
      image: _fallbackVisualImage,
      label: _item.displayTitle,
    ),
  ];

  @override
  Widget build(BuildContext context) {
    final parentMode = context.watch<AppState>().parentMode;
    final scene = _currentScene;
    final visibleLines = _visibleTranscriptLines;
    final playlist = _playlist;
    final showLyricsUi =
        _item.type == 'story' ||
        (_item.type == 'rhyme' && _transcript.isNotEmpty);
    return Scaffold(
      backgroundColor: const Color(0xFF1A1A2E),
      body: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
              child: Row(
                children: [
                  GestureDetector(
                    onTap: () async {
                      final navigator = Navigator.of(context);
                      await _persistPlaybackProgress();
                      final currentItem = _playbackRegisteredItem;
                      if (currentItem != null) {
                        await DeployedContentRepository.instance
                            .markPlaybackStopped(currentItem);
                        _playbackRegisteredItem = null;
                      }
                      if (!mounted) {
                        return;
                      }
                      if (widget.onBack != null) {
                        widget.onBack!();
                      } else {
                        navigator.pop();
                      }
                    },
                    child: const Icon(
                      Icons.arrow_back,
                      color: SunshineColors.white,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 4,
                    ),
                    decoration: BoxDecoration(
                      color: SunshineColors.pink.withValues(alpha: 0.2),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Text(
                      'Now Playing',
                      style: GoogleFonts.nunito(
                        fontSize: 10,
                        fontWeight: FontWeight.w700,
                        color: SunshineColors.pink,
                      ),
                    ),
                  ),
                  const Spacer(),
                  if (showLyricsUi)
                    GestureDetector(
                      onTap: () => setState(() => _lyricsOn = !_lyricsOn),
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 4,
                        ),
                        decoration: BoxDecoration(
                          color: _lyricsOn
                              ? SunshineColors.sunshineYellow.withValues(
                                  alpha: 0.2,
                                )
                              : Colors.white12,
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              Icons.menu_book,
                              size: 14,
                              color: _lyricsOn
                                  ? SunshineColors.sunshineYellow
                                  : Colors.white54,
                            ),
                            const SizedBox(width: 4),
                            Text(
                              'Lyrics ${_lyricsOn ? "On" : "Off"}',
                              style: GoogleFonts.nunito(
                                fontSize: 10,
                                fontWeight: FontWeight.w700,
                                color: _lyricsOn
                                    ? SunshineColors.sunshineYellow
                                    : Colors.white54,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 0),
              child: Column(
                children: [
                  Text(
                    _item.displayTitle,
                    style: GoogleFonts.nunito(
                      fontSize: 18,
                      fontWeight: FontWeight.w800,
                      color: SunshineColors.white,
                    ),
                    textAlign: TextAlign.center,
                  ),
                  if (playlist != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 5,
                        ),
                        decoration: BoxDecoration(
                          color: SunshineColors.white.withValues(alpha: 0.12),
                          borderRadius: BorderRadius.circular(14),
                        ),
                        child: Text(
                          'Playing • ${playlist.title} • ${(_playlistContext?.itemIndex ?? 0) + 1}/${playlist.itemCount}',
                          style: GoogleFonts.nunito(
                            fontSize: 11,
                            fontWeight: FontWeight.w800,
                            color: SunshineColors.white,
                          ),
                        ),
                      ),
                    ),
                  if (parentMode)
                    Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: GestureDetector(
                        onTap: () => showAddToPlaylistSheet(context, _item),
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 7,
                          ),
                          decoration: BoxDecoration(
                            color: SunshineColors.cream.withValues(alpha: 0.95),
                            borderRadius: BorderRadius.circular(16),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const Icon(
                                Icons.playlist_add,
                                size: 16,
                                color: SunshineColors.deepBlue,
                              ),
                              const SizedBox(width: 6),
                              Text(
                                'Add to Playlist',
                                style: GoogleFonts.nunito(
                                  fontSize: 11,
                                  fontWeight: FontWeight.w800,
                                  color: SunshineColors.deepBlue,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  if (_bundleLoading)
                    Padding(
                      padding: const EdgeInsets.only(top: 6),
                      child: Text(
                        'Preparing your next adventure...',
                        style: GoogleFonts.nunito(
                          fontSize: 11,
                          fontWeight: FontWeight.w600,
                          color: Colors.white70,
                        ),
                      ),
                    )
                  else if (_playlistTransitioning)
                    Padding(
                      padding: const EdgeInsets.only(top: 6),
                      child: Text(
                        'Getting the next item ready...',
                        style: GoogleFonts.nunito(
                          fontSize: 11,
                          fontWeight: FontWeight.w600,
                          color: Colors.white70,
                        ),
                      ),
                    )
                  else if (_bundleError != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 6),
                      child: Text(
                        _bundleError!,
                        style: GoogleFonts.nunito(
                          fontSize: 11,
                          fontWeight: FontWeight.w600,
                          color: Colors.white70,
                        ),
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(height: 10),
            Expanded(
              flex: 3,
              child: Container(
                margin: const EdgeInsets.symmetric(horizontal: 16),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(24),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.3),
                      blurRadius: 20,
                      offset: const Offset(0, 8),
                    ),
                  ],
                ),
                child: Stack(
                  children: [
                    ClipRRect(
                      borderRadius: BorderRadius.circular(24),
                      child: AnimatedSwitcher(
                        duration: const Duration(milliseconds: 500),
                        child: buildContentImage(
                          scene.image,
                          key: ValueKey(scene.id),
                          width: double.infinity,
                          height: double.infinity,
                          fit: BoxFit.cover,
                          errorBuilder: (context, error, stackTrace) =>
                              Container(
                                color: SunshineColors.lavender.withValues(
                                  alpha: 0.3,
                                ),
                                child: const Center(
                                  child: Icon(
                                    Icons.image,
                                    size: 48,
                                    color: Colors.white54,
                                  ),
                                ),
                              ),
                        ),
                      ),
                    ),
                    Positioned(
                      top: 12,
                      right: 12,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 4,
                        ),
                        decoration: BoxDecoration(
                          color: Colors.black54,
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: Text(
                          'Scene ${scene.number} / ${_scenes.length}',
                          style: GoogleFonts.nunito(
                            fontSize: 11,
                            fontWeight: FontWeight.w700,
                            color: SunshineColors.white,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            if (showLyricsUi && _lyricsOn)
              Container(
                margin: const EdgeInsets.fromLTRB(16, 12, 16, 0),
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 8,
                ),
                decoration: BoxDecoration(
                  color: const Color(0xFF1A1A2E),
                  borderRadius: BorderRadius.circular(18),
                  border: Border.all(color: Colors.white10),
                ),
                child: SizedBox(
                  height: 76,
                  child: Center(
                    child: visibleLines.isEmpty
                        ? Text(
                            'Transcript not available',
                            style: GoogleFonts.nunito(
                              fontSize: 14,
                              fontWeight: FontWeight.w700,
                              color: Colors.white54,
                            ),
                          )
                        : _buildTranscriptBlock(visibleLines),
                  ),
                ),
              ),
            const SizedBox(height: 10),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: Column(
                children: [
                  SliderTheme(
                    data: SliderThemeData(
                      trackHeight: 4,
                      thumbShape: const RoundSliderThumbShape(
                        enabledThumbRadius: 8,
                      ),
                      activeTrackColor: SunshineColors.pink,
                      inactiveTrackColor: Colors.white24,
                      thumbColor: SunshineColors.sunshineYellow,
                      overlayColor: SunshineColors.pink.withValues(alpha: 0.2),
                    ),
                    child: Slider(
                      value: _currentTime.clamp(0, _maxDurationSeconds),
                      min: 0,
                      max: _maxDurationSeconds,
                      onChanged: (value) {
                        _seekTo(value);
                      },
                    ),
                  ),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(
                        _formatTime(_currentTime),
                        style: GoogleFonts.nunito(
                          fontSize: 11,
                          fontWeight: FontWeight.w600,
                          color: Colors.white60,
                        ),
                      ),
                      Text(
                        _item.durationSeconds > 0
                            ? _item.duration
                            : _formatTime(_maxDurationSeconds),
                        style: GoogleFonts.nunito(
                          fontSize: 11,
                          fontWeight: FontWeight.w600,
                          color: Colors.white60,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: [
                  _ControlBtn(
                    icon: Icons.replay_10,
                    onTap: () => _seekTo(_currentTime - 10),
                  ),
                  _ControlBtn(
                    icon: Icons.skip_previous,
                    onTap: _goToPreviousPlaylistItem,
                  ),
                  GestureDetector(
                    onTap: _togglePlay,
                    child: Container(
                      width: 64,
                      height: 64,
                      decoration: BoxDecoration(
                        gradient: SunshineColors.pinkGradient,
                        shape: BoxShape.circle,
                        boxShadow: [
                          BoxShadow(
                            color: SunshineColors.pink.withValues(alpha: 0.4),
                            blurRadius: 16,
                            offset: const Offset(0, 4),
                          ),
                        ],
                      ),
                      child: Icon(
                        _playing ? Icons.pause : Icons.play_arrow_rounded,
                        color: SunshineColors.white,
                        size: 36,
                      ),
                    ),
                  ),
                  _ControlBtn(
                    icon: Icons.skip_next,
                    onTap: _goToNextPlaylistItem,
                  ),
                  _ControlBtn(icon: Icons.volume_up, onTap: () {}),
                ],
              ),
            ),
            SizedBox(
              height: 80,
              child: ListView.builder(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 16),
                itemCount: _scenes.length,
                itemBuilder: (context, index) {
                  final sceneItem = _scenes[index];
                  return SceneThumbnail(
                    scene: sceneItem,
                    isCurrent: sceneItem.id == scene.id,
                    onTap: () => _seekTo(sceneItem.start),
                  );
                },
              ),
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  Widget _buildTranscriptBlock(List<_TranscriptDisplayLine> lines) {
    final baseStyle = GoogleFonts.nunito(
      fontSize: 18,
      fontWeight: FontWeight.w800,
      color: SunshineColors.white,
      height: 1.35,
    );

    final children = <InlineSpan>[];
    for (var lineIndex = 0; lineIndex < lines.length; lineIndex++) {
      final line = lines[lineIndex];
      final words = line.words;
      if (words.isEmpty) {
        continue;
      }
      if (children.isNotEmpty) {
        children.add(const TextSpan(text: '\n'));
      }
      for (var wordIndex = 0; wordIndex < words.length; wordIndex++) {
        if (wordIndex > 0) {
          children.add(const TextSpan(text: ' '));
        }
        children.add(
          TextSpan(
            text: words[wordIndex].word,
            style: _styleForTranscriptWord(words[wordIndex], baseStyle),
          ),
        );
      }
      if (line.truncated) {
        children.add(TextSpan(text: '…', style: baseStyle));
      }
    }

    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Text.rich(
        TextSpan(children: children),
        textAlign: TextAlign.center,
        maxLines: 2,
        overflow: TextOverflow.clip,
      ),
    );
  }

  TextStyle _styleForTranscriptWord(TranscriptWord word, TextStyle baseStyle) {
    final isCurrent = _currentTime >= word.start && _currentTime <= word.end;
    if (isCurrent) {
      return baseStyle.copyWith(color: SunshineColors.pink);
    }
    return baseStyle;
  }
}

class _TranscriptDisplayLine {
  final int lineNumber;
  final List<TranscriptWord> words;
  final bool truncated;

  const _TranscriptDisplayLine({
    required this.lineNumber,
    required this.words,
    this.truncated = false,
  });
}

class _StoryTranscriptChunk {
  final int startIndex;
  final int endIndex;
  final List<TranscriptWord> words;

  const _StoryTranscriptChunk({
    required this.startIndex,
    required this.endIndex,
    required this.words,
  });
}

class _ControlBtn extends StatelessWidget {
  final IconData icon;
  final VoidCallback? onTap;
  const _ControlBtn({required this.icon, this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 44,
        height: 44,
        decoration: const BoxDecoration(
          color: Colors.white12,
          shape: BoxShape.circle,
        ),
        child: Icon(icon, color: Colors.white70, size: 22),
      ),
    );
  }
}
