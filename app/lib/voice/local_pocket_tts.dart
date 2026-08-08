import 'dart:async';
import 'dart:developer' as developer;
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa;

import 'audio_bridge.dart';
import 'talk_voice_preferences.dart';
import 'voice_model_assets.dart';

const int _defaultSampleRate = 24000;
const int _defaultConsistencySteps = 6;
const int _defaultNumThreads = 2;
const double _speechTargetRms = 0.095;
const double _speechActiveSampleFloor = 0.008;
const double _speechPeakCeiling = 0.94;
const double _speechMinGain = 0.45;
const double _speechMaxGain = 2.4;

var _sherpaBindingsInitialized = false;

class LocalPocketTts {
  LocalPocketTts(this._audio, {int numThreads = _defaultNumThreads})
    : _numThreads = math.max(1, numThreads);

  final SparkAudioBridge _audio;
  final int _numThreads;
  _PocketTtsWorkerController? _worker;
  int _playbackGeneration = 0;
  Future<void> _playbackWriteTail = Future<void>.value();

  Future<void> prepare({String? referenceAudioPath}) async {
    final VoiceModelAssetPaths assets = await VoiceModelAssetStore.instance
        .ensureVoiceModelPack();
    final String referencePath = await _resolveReferenceAudioPath(
      referenceAudioPath,
      assets: assets,
    );
    await _workerFor(assets.pocketTtsModelDir, referencePath);
  }

  Future<LocalPocketTtsResult> speak(
    String text, {
    int consistencySteps = _defaultConsistencySteps,
    bool restartPlayback = true,
    int? playbackSessionId,
    String? referenceAudioPath,
    double speed = talkVoiceSpeedDefault,
    int pcmPrerollMs = 0,
    void Function(LocalPocketTtsPlaybackProgress progress)? onProgress,
  }) async {
    final String trimmed = text.trim();
    if (trimmed.isEmpty) {
      return const LocalPocketTtsResult.empty();
    }
    final int generation = _playbackGeneration + 1;
    _playbackGeneration = generation;
    final int sessionId = playbackSessionId ?? generation;

    final VoiceModelAssetPaths assets = await VoiceModelAssetStore.instance
        .ensureVoiceModelPack();
    final String referencePath = await _resolveReferenceAudioPath(
      referenceAudioPath,
      assets: assets,
    );
    final _PocketTtsWorkerController worker = await _workerFor(
      assets.pocketTtsModelDir,
      referencePath,
    );
    if (generation != _playbackGeneration) {
      return const LocalPocketTtsResult.empty();
    }

    if (restartPlayback) {
      await _audio.stopPlayback();
    }
    final bool playbackStarted = await _audio.startPlayback(
      sampleRate: _defaultSampleRate,
      sessionId: sessionId,
    );
    if (!playbackStarted) {
      throw StateError('Local audio playback did not start.');
    }
    if (generation != _playbackGeneration) {
      return const LocalPocketTtsResult.empty();
    }

    final Stopwatch stopwatch = Stopwatch()..start();
    int chunks = 0;
    int bytes = 0;
    double? ttfaMs;

    final LocalPocketTtsResult result = await worker.synthesize(
      _PocketTtsRequest(
        text: trimmed,
        consistencySteps: math.max(1, consistencySteps),
        speed: clampTalkVoiceSpeed(speed),
      ),
      onChunk: (Float32List samples, int sampleRate, double? chunkTtfaMs) {
        if (generation != _playbackGeneration) {
          return;
        }
        chunks += 1;
        final int chunkIndex = chunks;
        ttfaMs ??= chunkTtfaMs;
        final _Pcm16Conversion pcm16 = _float32ToNormalizedPcm16(samples);
        final int safePrerollMs = math.max(0, pcmPrerollMs);
        final Uint8List playbackPcm16 = chunkIndex == 1 && safePrerollMs > 0
            ? _prependPcm16Silence(
                pcm16.bytes,
                sampleRate: sampleRate,
                durationMs: safePrerollMs,
              )
            : pcm16.bytes;
        bytes += playbackPcm16.length;
        final int totalBytesAtChunk = bytes;
        _playbackWriteTail = _playbackWriteTail
            .catchError((_) {
              // A failed write will be surfaced by the current request path.
            })
            .then((_) async {
              if (generation == _playbackGeneration) {
                await _audio.writePlayback(playbackPcm16, sessionId: sessionId);
                Map<String, dynamic>? nativeStatus;
                try {
                  nativeStatus = await _audio.playbackStatus();
                } catch (error) {
                  nativeStatus = <String, dynamic>{
                    'playbackStatusError': error.toString(),
                  };
                }
                onProgress?.call(
                  LocalPocketTtsPlaybackProgress(
                    chunkIndex: chunkIndex,
                    sampleRate: sampleRate,
                    samples: samples.length,
                    pcmBytes: playbackPcm16.length,
                    totalPcmBytes: totalBytesAtChunk,
                    normalizationGain: pcm16.gain,
                    sourceRms: pcm16.sourceRms,
                    sourcePeak: pcm16.sourcePeak,
                    ttfaMilliseconds: ttfaMs,
                    nativeStatus: nativeStatus,
                  ),
                );
              }
            });
      },
    );
    await _playbackWriteTail;

    stopwatch.stop();
    developer.log(
      'Local PocketTTS spoke ${trimmed.length} chars, '
      'chunks=$chunks, audioBytes=$bytes, '
      'ttfa=${ttfaMs?.toStringAsFixed(0) ?? 'n/a'}ms, '
      'elapsed=${stopwatch.elapsedMilliseconds}ms',
      name: 'StoryVaultTalk',
    );

    return result.copyWith(
      chunks: chunks,
      audioBytes: bytes,
      ttfaMilliseconds: ttfaMs,
    );
  }

  Future<void> stop({bool resetWorker = false}) async {
    _playbackGeneration += 1;
    await _playbackWriteTail.catchError((_) {
      // Stopping playback is best-effort even if an earlier write failed.
    });
    if (resetWorker) {
      _worker?.dispose();
      _worker = null;
    }
    await _audio.stopPlayback();
  }

  Future<void> dispose() async {
    await stop(resetWorker: true);
    _worker?.dispose();
    _worker = null;
  }

  Future<_PocketTtsWorkerController> _workerFor(
    String modelDir,
    String referenceAudioPath,
  ) async {
    final _PocketTtsWorkerController? existing = _worker;
    if (existing != null &&
        existing.modelDir == modelDir &&
        existing.referenceAudioPath == referenceAudioPath) {
      return existing;
    }

    existing?.dispose();
    final _PocketTtsWorkerController next =
        await _PocketTtsWorkerController.start(
          modelDir: modelDir,
          referenceAudioPath: referenceAudioPath,
          numThreads: _numThreads,
        );
    _worker = next;
    return next;
  }
}

class LocalPocketTtsPlaybackProgress {
  const LocalPocketTtsPlaybackProgress({
    required this.chunkIndex,
    required this.sampleRate,
    required this.samples,
    required this.pcmBytes,
    required this.totalPcmBytes,
    required this.normalizationGain,
    required this.sourceRms,
    required this.sourcePeak,
    required this.ttfaMilliseconds,
    required this.nativeStatus,
  });

  final int chunkIndex;
  final int sampleRate;
  final int samples;
  final int pcmBytes;
  final int totalPcmBytes;
  final double normalizationGain;
  final double sourceRms;
  final double sourcePeak;
  final double? ttfaMilliseconds;
  final Map<String, dynamic>? nativeStatus;
}

class LocalPocketTtsResult {
  const LocalPocketTtsResult({
    required this.synthesisTimeSeconds,
    required this.audioDurationSeconds,
    required this.realtimeFactor,
    required this.chunks,
    required this.audioBytes,
    required this.ttfaMilliseconds,
  });

  const LocalPocketTtsResult.empty()
    : synthesisTimeSeconds = 0,
      audioDurationSeconds = 0,
      realtimeFactor = 0,
      chunks = 0,
      audioBytes = 0,
      ttfaMilliseconds = null;

  final double synthesisTimeSeconds;
  final double audioDurationSeconds;
  final double realtimeFactor;
  final int chunks;
  final int audioBytes;
  final double? ttfaMilliseconds;

  LocalPocketTtsResult copyWith({
    int? chunks,
    int? audioBytes,
    double? ttfaMilliseconds,
  }) {
    return LocalPocketTtsResult(
      synthesisTimeSeconds: synthesisTimeSeconds,
      audioDurationSeconds: audioDurationSeconds,
      realtimeFactor: realtimeFactor,
      chunks: chunks ?? this.chunks,
      audioBytes: audioBytes ?? this.audioBytes,
      ttfaMilliseconds: ttfaMilliseconds ?? this.ttfaMilliseconds,
    );
  }
}

class PocketTtsBenchmarkSample {
  const PocketTtsBenchmarkSample({
    required this.synthesisMilliseconds,
    required this.audioDurationMilliseconds,
    required this.realtimeFactor,
    required this.sampleRate,
    required this.sampleCount,
    required this.rms,
    required this.peak,
    required this.validAudio,
  });

  final double synthesisMilliseconds;
  final double audioDurationMilliseconds;
  final double realtimeFactor;
  final int sampleRate;
  final int sampleCount;
  final double rms;
  final double peak;
  final bool validAudio;
}

/// A playback-independent PocketTTS runner used by first-boot preparation.
///
/// Keeping this beside the production worker ensures the benchmark exercises
/// the same model, cloning path, thread configuration, and generation steps.
class PocketTtsBenchmarkEngine {
  _PocketTtsWorkerController? _worker;

  Future<double> initialize({int numThreads = _defaultNumThreads}) async {
    await dispose();
    final Stopwatch stopwatch = Stopwatch()..start();
    final VoiceModelAssetPaths assets = await VoiceModelAssetStore.instance
        .ensureVoiceModelPack();
    _worker = await _PocketTtsWorkerController.start(
      modelDir: assets.pocketTtsModelDir,
      referenceAudioPath: assets.defaultReferenceAudioPath,
      numThreads: math.max(1, numThreads),
    );
    stopwatch.stop();
    return stopwatch.elapsedMicroseconds / 1000.0;
  }

  Future<PocketTtsBenchmarkSample> synthesize(
    String text, {
    int consistencySteps = _defaultConsistencySteps,
    double speed = talkVoiceSpeedDefault,
  }) async {
    final _PocketTtsWorkerController? worker = _worker;
    if (worker == null) {
      throw StateError('PocketTTS benchmark engine is not initialized.');
    }

    Float32List? generatedSamples;
    var sampleRate = 0;
    final LocalPocketTtsResult result = await worker.synthesize(
      _PocketTtsRequest(
        text: text.trim(),
        consistencySteps: math.max(1, consistencySteps),
        speed: clampTalkVoiceSpeed(speed),
      ),
      onChunk: (Float32List samples, int rate, double? _) {
        generatedSamples = samples;
        sampleRate = rate;
      },
    );

    final Float32List samples = generatedSamples ?? Float32List(0);
    final _SpeechLevel level = _measureSpeechLevel(samples);
    final bool finite = samples.every((double sample) => sample.isFinite);
    final double audioDurationMs = sampleRate > 0
        ? samples.length * 1000.0 / sampleRate
        : 0;
    return PocketTtsBenchmarkSample(
      synthesisMilliseconds: result.synthesisTimeSeconds * 1000.0,
      audioDurationMilliseconds: audioDurationMs,
      realtimeFactor: audioDurationMs > 0
          ? result.synthesisTimeSeconds / (audioDurationMs / 1000.0)
          : double.infinity,
      sampleRate: sampleRate,
      sampleCount: samples.length,
      rms: level.rms,
      peak: level.peak,
      validAudio:
          finite &&
          samples.isNotEmpty &&
          sampleRate == _defaultSampleRate &&
          audioDurationMs >= 250 &&
          level.rms > 0.001 &&
          level.peak <= 1.05,
    );
  }

  Future<void> dispose() async {
    await _worker?.disposeGracefully();
    _worker = null;
  }
}

class _PocketTtsWorkerController {
  _PocketTtsWorkerController._({
    required this.modelDir,
    required this.referenceAudioPath,
    required this.numThreads,
    required Isolate isolate,
    required SendPort sendPort,
    required ReceivePort receivePort,
    required Stream<dynamic> receiveStream,
  }) : _isolate = isolate,
       _sendPort = sendPort,
       _receivePort = receivePort {
    _subscription = receiveStream.listen(_handleMessage);
  }

  final String modelDir;
  final String referenceAudioPath;
  final int numThreads;
  final Isolate _isolate;
  final SendPort _sendPort;
  final ReceivePort _receivePort;
  late final StreamSubscription<dynamic> _subscription;
  final Completer<void> _ready = Completer<void>();
  final Completer<void> _disposed = Completer<void>();
  bool _closed = false;

  Completer<LocalPocketTtsResult>? _pending;
  void Function(Float32List samples, int sampleRate, double? ttfaMs)? _onChunk;

  static Future<_PocketTtsWorkerController> start({
    required String modelDir,
    required String referenceAudioPath,
    required int numThreads,
  }) async {
    final ReceivePort receivePort = ReceivePort();
    final Stream<dynamic> receiveStream = receivePort.asBroadcastStream();
    final Isolate isolate = await Isolate.spawn(
      _pocketTtsWorkerMain,
      receivePort.sendPort,
      debugName: 'storyvault-pocket-tts',
    );

    final SendPort sendPort = await receiveStream.first as SendPort;
    final _PocketTtsWorkerController controller = _PocketTtsWorkerController._(
      modelDir: modelDir,
      referenceAudioPath: referenceAudioPath,
      numThreads: numThreads,
      isolate: isolate,
      sendPort: sendPort,
      receivePort: receivePort,
      receiveStream: receiveStream,
    );
    sendPort.send(<String, Object?>{
      'type': 'init',
      'modelDir': modelDir,
      'referenceAudioPath': referenceAudioPath,
      'numThreads': numThreads,
    });
    try {
      await controller._ready.future.timeout(const Duration(seconds: 20));
    } catch (_) {
      controller.dispose();
      rethrow;
    }
    return controller;
  }

  Future<LocalPocketTtsResult> synthesize(
    _PocketTtsRequest request, {
    required void Function(Float32List samples, int sampleRate, double? ttfaMs)
    onChunk,
  }) async {
    if (_pending != null) {
      throw StateError('Local PocketTTS is already speaking.');
    }
    final Completer<LocalPocketTtsResult> completer =
        Completer<LocalPocketTtsResult>();
    _pending = completer;
    _onChunk = onChunk;
    _sendPort.send(<String, Object?>{
      'type': 'synthesize',
      'text': request.text,
      'consistencySteps': request.consistencySteps,
      'speed': request.speed,
      'startedAtMicros': DateTime.now().microsecondsSinceEpoch,
    });
    return completer.future.whenComplete(() {
      _pending = null;
      _onChunk = null;
    });
  }

  void _handleMessage(dynamic message) {
    if (message is! Map) {
      return;
    }
    final String type = message['type'] as String? ?? '';
    switch (type) {
      case 'ready':
        if (!_ready.isCompleted) {
          _ready.complete();
        }
      case 'disposed':
        if (!_disposed.isCompleted) {
          _disposed.complete();
        }
      case 'chunk':
        final Object? rawSamples = message['samples'];
        if (rawSamples is Float32List) {
          _onChunk?.call(
            rawSamples,
            message['sampleRate'] as int? ?? _defaultSampleRate,
            (message['ttfaMilliseconds'] as num?)?.toDouble(),
          );
        }
      case 'done':
        final Completer<LocalPocketTtsResult>? pending = _pending;
        if (pending != null && !pending.isCompleted) {
          pending.complete(
            LocalPocketTtsResult(
              synthesisTimeSeconds:
                  (message['synthesisTimeSeconds'] as num?)?.toDouble() ?? 0,
              audioDurationSeconds:
                  (message['audioDurationSeconds'] as num?)?.toDouble() ?? 0,
              realtimeFactor:
                  (message['realtimeFactor'] as num?)?.toDouble() ?? 0,
              chunks: 0,
              audioBytes: 0,
              ttfaMilliseconds: null,
            ),
          );
        }
      case 'error':
        if (!_ready.isCompleted) {
          _ready.completeError(
            StateError(message['message'] as String? ?? 'PocketTTS failed.'),
          );
        }
        final Completer<LocalPocketTtsResult>? pending = _pending;
        if (pending != null && !pending.isCompleted) {
          pending.completeError(
            StateError(message['message'] as String? ?? 'PocketTTS failed.'),
          );
        }
      default:
        break;
    }
  }

  void dispose() {
    _completePendingStop();
    _close();
  }

  Future<void> disposeGracefully() async {
    if (_closed) {
      return;
    }
    if (_pending != null) {
      dispose();
      return;
    }
    _sendPort.send(const <String, Object?>{'type': 'dispose'});
    try {
      await _disposed.future.timeout(const Duration(seconds: 2));
    } catch (_) {
      // Fall through to isolate termination if native cleanup cannot respond.
    } finally {
      _close();
    }
  }

  void _completePendingStop() {
    if (!_ready.isCompleted) {
      _ready.completeError(StateError('Local PocketTTS worker was stopped.'));
    }
    final Completer<LocalPocketTtsResult>? pending = _pending;
    if (pending != null && !pending.isCompleted) {
      pending.completeError(StateError('Local PocketTTS worker was stopped.'));
    }
    _pending = null;
    _onChunk = null;
  }

  void _close() {
    if (_closed) {
      return;
    }
    _closed = true;
    _subscription.cancel();
    _receivePort.close();
    _isolate.kill(priority: Isolate.immediate);
  }
}

class _PocketTtsRequest {
  const _PocketTtsRequest({
    required this.text,
    required this.consistencySteps,
    required this.speed,
  });

  final String text;
  final int consistencySteps;
  final double speed;
}

Future<String> _resolveReferenceAudioPath(
  String? preferredPath, {
  required VoiceModelAssetPaths assets,
}) async {
  final String? trimmed = preferredPath?.trim();
  if (trimmed != null && trimmed.isNotEmpty) {
    final File file = File(trimmed);
    if (await file.exists() && await file.length() > 0) {
      return file.path;
    }
  }
  return assets.defaultReferenceAudioPath;
}

void _pocketTtsWorkerMain(SendPort mainSendPort) {
  final ReceivePort workerReceivePort = ReceivePort();
  mainSendPort.send(workerReceivePort.sendPort);

  sherpa.OfflineTts? tts;
  sherpa.WaveData? referenceWave;

  workerReceivePort.listen((dynamic message) {
    if (message is! Map) {
      return;
    }
    final SendPort sendPort = mainSendPort;
    final String type = message['type'] as String? ?? '';
    try {
      if (!_sherpaBindingsInitialized) {
        sherpa.initBindings();
        _sherpaBindingsInitialized = true;
      }

      switch (type) {
        case 'init':
          final String modelDir = message['modelDir'] as String;
          final String referenceAudioPath =
              message['referenceAudioPath'] as String;
          final int numThreads = math.max(
            1,
            message['numThreads'] as int? ?? _defaultNumThreads,
          );
          tts?.free();
          tts = _createPocketTts(modelDir, numThreads: numThreads);
          referenceWave = sherpa.readWave(referenceAudioPath);
          if (referenceWave!.samples.isEmpty ||
              referenceWave!.sampleRate == 0) {
            throw StateError('Default PocketTTS reference audio is empty.');
          }
          sendPort.send(const <String, Object?>{'type': 'ready'});
        case 'synthesize':
          final sherpa.OfflineTts? activeTts = tts;
          final sherpa.WaveData? activeReference = referenceWave;
          if (activeTts == null || activeReference == null) {
            throw StateError('Local PocketTTS worker is not initialized.');
          }
          _runPocketTtsGeneration(
            sendPort: sendPort,
            tts: activeTts,
            referenceWave: activeReference,
            text: message['text'] as String? ?? '',
            consistencySteps: math.max(
              1,
              message['consistencySteps'] as int? ?? 6,
            ),
            speed: clampTalkVoiceSpeed(
              (message['speed'] as num?)?.toDouble() ?? talkVoiceSpeedDefault,
            ),
            startedAtMicros: message['startedAtMicros'] as int?,
          );
        case 'dispose':
          tts?.free();
          tts = null;
          referenceWave = null;
          sendPort.send(const <String, Object?>{'type': 'disposed'});
          workerReceivePort.close();
        default:
          break;
      }
    } catch (error, stackTrace) {
      developer.log(
        'Local PocketTTS worker failed',
        name: 'StoryVaultTalk',
        error: error,
        stackTrace: stackTrace,
      );
      sendPort.send(<String, Object?>{
        'type': 'error',
        'message': error.toString(),
      });
    }
  });
}

sherpa.OfflineTts _createPocketTts(String modelDir, {required int numThreads}) {
  final sherpa.OfflineTtsPocketModelConfig pocket =
      sherpa.OfflineTtsPocketModelConfig(
        lmFlow: '$modelDir/lm_flow.int8.onnx',
        lmMain: '$modelDir/lm_main.int8.onnx',
        encoder: '$modelDir/encoder.onnx',
        decoder: '$modelDir/decoder.int8.onnx',
        textConditioner: '$modelDir/text_conditioner.onnx',
        vocabJson: '$modelDir/vocab.json',
        tokenScoresJson: '$modelDir/token_scores.json',
        voiceEmbeddingCacheCapacity: 4,
      );
  final sherpa.OfflineTtsModelConfig modelConfig = sherpa.OfflineTtsModelConfig(
    pocket: pocket,
    numThreads: numThreads,
    debug: false,
    provider: 'cpu',
  );
  return sherpa.OfflineTts(sherpa.OfflineTtsConfig(model: modelConfig));
}

void _runPocketTtsGeneration({
  required SendPort sendPort,
  required sherpa.OfflineTts tts,
  required sherpa.WaveData referenceWave,
  required String text,
  required int consistencySteps,
  required double speed,
  required int? startedAtMicros,
}) {
  final Stopwatch stopwatch = Stopwatch()..start();
  final sherpa.GeneratedAudio audio = tts.generateWithConfig(
    text: text,
    config: sherpa.OfflineTtsGenerationConfig(
      speed: speed,
      referenceAudio: referenceWave.samples,
      referenceSampleRate: referenceWave.sampleRate,
      numSteps: consistencySteps,
      extra: const <String, Object>{'max_reference_audio_len': 12, 'seed': 42},
    ),
  );
  stopwatch.stop();

  if (audio.samples.isEmpty || audio.sampleRate == 0) {
    throw StateError('Local PocketTTS returned empty audio.');
  }
  final double ttfaMilliseconds = startedAtMicros == null
      ? stopwatch.elapsedMicroseconds / 1000.0
      : (DateTime.now().microsecondsSinceEpoch - startedAtMicros) / 1000.0;
  sendPort.send(<String, Object?>{
    'type': 'chunk',
    'samples': audio.samples,
    'sampleRate': audio.sampleRate,
    'ttfaMilliseconds': ttfaMilliseconds,
    'progressCallback': false,
  });

  final double synthesisTimeSeconds = math.max(
    stopwatch.elapsedMicroseconds / 1000000.0,
    0.001,
  );
  final double audioDurationSeconds = audio.samples.length / audio.sampleRate;
  sendPort.send(<String, Object?>{
    'type': 'done',
    'synthesisTimeSeconds': synthesisTimeSeconds,
    'audioDurationSeconds': audioDurationSeconds,
    'realtimeFactor': synthesisTimeSeconds / audioDurationSeconds,
  });
}

class _Pcm16Conversion {
  const _Pcm16Conversion({
    required this.bytes,
    required this.gain,
    required this.sourceRms,
    required this.sourcePeak,
  });

  final Uint8List bytes;
  final double gain;
  final double sourceRms;
  final double sourcePeak;

  int get length => bytes.length;
}

_Pcm16Conversion _float32ToNormalizedPcm16(Float32List samples) {
  final _SpeechLevel level = _measureSpeechLevel(samples);
  final double gain = _normalizationGainFor(level);
  final ByteData data = ByteData(samples.length * 2);
  for (int i = 0; i < samples.length; i += 1) {
    final double clamped = (samples[i] * gain).clamp(-1.0, 1.0);
    data.setInt16(i * 2, (clamped * 32767).round(), Endian.little);
  }
  return _Pcm16Conversion(
    bytes: data.buffer.asUint8List(),
    gain: gain,
    sourceRms: level.rms,
    sourcePeak: level.peak,
  );
}

Uint8List _prependPcm16Silence(
  Uint8List pcm16, {
  required int sampleRate,
  required int durationMs,
}) {
  if (pcm16.isEmpty || sampleRate <= 0 || durationMs <= 0) {
    return pcm16;
  }
  final int silentSamples = (sampleRate * durationMs / 1000).round();
  if (silentSamples <= 0) {
    return pcm16;
  }
  final int silenceBytes = silentSamples * 2;
  final Uint8List output = Uint8List(silenceBytes + pcm16.length);
  output.setRange(silenceBytes, output.length, pcm16);
  return output;
}

class _SpeechLevel {
  const _SpeechLevel({required this.rms, required this.peak});

  final double rms;
  final double peak;
}

_SpeechLevel _measureSpeechLevel(Float32List samples) {
  if (samples.isEmpty) {
    return const _SpeechLevel(rms: 0, peak: 0);
  }
  var activeSquareSum = 0.0;
  var activeSamples = 0;
  var peak = 0.0;
  for (final double sample in samples) {
    final double magnitude = sample.abs();
    if (magnitude > peak) {
      peak = magnitude;
    }
    if (magnitude >= _speechActiveSampleFloor) {
      activeSquareSum += sample * sample;
      activeSamples += 1;
    }
  }
  if (activeSamples == 0) {
    return _SpeechLevel(rms: 0, peak: peak);
  }
  return _SpeechLevel(
    rms: math.sqrt(activeSquareSum / activeSamples),
    peak: peak,
  );
}

double _normalizationGainFor(_SpeechLevel level) {
  if (level.rms <= 0 || level.peak <= 0) {
    return 1.0;
  }
  final double rmsGain = (_speechTargetRms / level.rms).clamp(
    _speechMinGain,
    _speechMaxGain,
  );
  final double peakGain = _speechPeakCeiling / level.peak;
  return math.min(rmsGain, peakGain).clamp(_speechMinGain, _speechMaxGain);
}
