import 'dart:async';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa;

import 'voice_model_assets.dart';

var _sherpaBindingsInitialized = false;

class LocalWhisperAsr {
  const LocalWhisperAsr();

  Future<LocalWhisperAsrResult> transcribePcm16Frames(
    List<Uint8List> frames, {
    required int sampleRate,
    int numThreads = 2,
  }) async {
    if (frames.isEmpty || sampleRate <= 0) {
      return const LocalWhisperAsrResult.empty();
    }
    final VoiceModelAssetPaths assets = await VoiceModelAssetStore.instance
        .ensureVoiceModelPack();
    final Float32List samples = _pcm16FramesToFloat32(frames);
    if (samples.isEmpty) {
      return const LocalWhisperAsrResult.empty();
    }

    final Stopwatch stopwatch = Stopwatch()..start();
    final String text = await Isolate.run(() {
      return _runWhisper(
        _WhisperRequest(
          modelDir: assets.whisperAsrModelDir,
          samples: samples,
          sampleRate: sampleRate,
          numThreads: numThreads < 1 ? 1 : numThreads,
        ),
      );
    });
    stopwatch.stop();

    return LocalWhisperAsrResult(
      text: text.trim(),
      elapsedMilliseconds: stopwatch.elapsedMilliseconds,
      audioDurationSeconds: samples.length / sampleRate,
      sampleCount: samples.length,
    );
  }
}

/// Keeps Whisper allocated while the first-boot LLM benchmark runs.
///
/// No transcription is needed here; the lease exists so memory and thermal
/// measurements represent the production ASR + TTS + LLM resident set.
class LocalWhisperAsrBenchmarkLease {
  LocalWhisperAsrBenchmarkLease._(this._isolate, this._controlPort);

  final Isolate _isolate;
  final SendPort _controlPort;
  bool _disposed = false;

  static Future<LocalWhisperAsrBenchmarkLease> load({
    int numThreads = 2,
  }) async {
    final VoiceModelAssetPaths assets = await VoiceModelAssetStore.instance
        .ensureVoiceModelPack();
    final ReceivePort readyPort = ReceivePort();
    final Isolate isolate = await Isolate.spawn(
      _residentWhisperWorker,
      <Object>[
        readyPort.sendPort,
        assets.whisperAsrModelDir,
        numThreads < 1 ? 1 : numThreads,
      ],
      debugName: 'storyvault-whisper-benchmark-resident',
    );
    final Object? ready = await readyPort.first.timeout(
      const Duration(seconds: 20),
    );
    readyPort.close();
    if (ready is Map && ready['control'] is SendPort) {
      return LocalWhisperAsrBenchmarkLease._(
        isolate,
        ready['control'] as SendPort,
      );
    }
    isolate.kill(priority: Isolate.immediate);
    final String message = ready is Map
        ? ready['error']?.toString() ?? 'unknown error'
        : 'worker did not become ready';
    throw StateError('Whisper benchmark preload failed: $message');
  }

  Future<void> dispose() async {
    if (_disposed) {
      return;
    }
    _disposed = true;
    final ReceivePort acknowledgement = ReceivePort();
    _controlPort.send(<Object>['dispose', acknowledgement.sendPort]);
    try {
      await acknowledgement.first.timeout(const Duration(seconds: 3));
    } finally {
      acknowledgement.close();
      _isolate.kill(priority: Isolate.immediate);
    }
  }
}

class LocalWhisperAsrResult {
  const LocalWhisperAsrResult({
    required this.text,
    required this.elapsedMilliseconds,
    required this.audioDurationSeconds,
    required this.sampleCount,
  });

  const LocalWhisperAsrResult.empty()
    : text = '',
      elapsedMilliseconds = 0,
      audioDurationSeconds = 0,
      sampleCount = 0;

  final String text;
  final int elapsedMilliseconds;
  final double audioDurationSeconds;
  final int sampleCount;
}

class _WhisperRequest {
  const _WhisperRequest({
    required this.modelDir,
    required this.samples,
    required this.sampleRate,
    required this.numThreads,
  });

  final String modelDir;
  final Float32List samples;
  final int sampleRate;
  final int numThreads;
}

String _runWhisper(_WhisperRequest request) {
  if (!_sherpaBindingsInitialized) {
    sherpa.initBindings();
    _sherpaBindingsInitialized = true;
  }

  final sherpa.OfflineRecognizer recognizer = _createWhisperRecognizer(
    request.modelDir,
    request.numThreads,
  );
  final sherpa.OfflineStream stream = recognizer.createStream();
  try {
    stream.acceptWaveform(
      samples: request.samples,
      sampleRate: request.sampleRate,
    );
    recognizer.decode(stream);
    return recognizer.getResult(stream).text;
  } finally {
    stream.free();
    recognizer.free();
  }
}

sherpa.OfflineRecognizer _createWhisperRecognizer(
  String modelDir,
  int numThreads,
) {
  return sherpa.OfflineRecognizer(
    sherpa.OfflineRecognizerConfig(
      model: sherpa.OfflineModelConfig(
        whisper: sherpa.OfflineWhisperModelConfig(
          encoder: '$modelDir/tiny.en-encoder.int8.onnx',
          decoder: '$modelDir/tiny.en-decoder.int8.onnx',
          language: 'en',
          task: 'transcribe',
        ),
        tokens: '$modelDir/tiny.en-tokens.txt',
        numThreads: numThreads,
        provider: 'cpu',
        debug: false,
      ),
    ),
  );
}

void _residentWhisperWorker(List<Object> arguments) {
  final SendPort readyPort = arguments[0] as SendPort;
  final String modelDir = arguments[1] as String;
  final int numThreads = arguments[2] as int;
  sherpa.OfflineRecognizer? recognizer;
  try {
    if (!_sherpaBindingsInitialized) {
      sherpa.initBindings();
      _sherpaBindingsInitialized = true;
    }
    recognizer = _createWhisperRecognizer(modelDir, numThreads);
    final ReceivePort control = ReceivePort();
    readyPort.send(<String, Object>{'control': control.sendPort});
    control.listen((Object? message) {
      if (message is List && message.isNotEmpty && message.first == 'dispose') {
        recognizer?.free();
        recognizer = null;
        if (message.length > 1 && message[1] is SendPort) {
          (message[1] as SendPort).send(true);
        }
        control.close();
      }
    });
  } catch (error) {
    recognizer?.free();
    readyPort.send(<String, Object>{'error': error.toString()});
  }
}

Float32List _pcm16FramesToFloat32(List<Uint8List> frames) {
  var totalBytes = 0;
  for (final Uint8List frame in frames) {
    totalBytes += frame.lengthInBytes - (frame.lengthInBytes % 2);
  }
  if (totalBytes <= 0) {
    return Float32List(0);
  }

  final Float32List samples = Float32List(totalBytes ~/ 2);
  var offset = 0;
  for (final Uint8List frame in frames) {
    final ByteData data = ByteData.sublistView(frame);
    final int sampleCount = frame.lengthInBytes ~/ 2;
    for (var i = 0; i < sampleCount; i++) {
      samples[offset] = data.getInt16(i * 2, Endian.little) / 32768.0;
      offset += 1;
    }
  }
  return samples;
}
