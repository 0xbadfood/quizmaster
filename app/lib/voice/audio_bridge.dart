import 'package:flutter/services.dart';

class SparkMicFrame {
  const SparkMicFrame({
    required this.pcm16,
    required this.vadSource,
    this.isSpeech,
    this.vadMode = '',
  });

  factory SparkMicFrame.fromEvent(Object? event) {
    if (event is Uint8List || event is List<int>) {
      return SparkMicFrame(pcm16: _bytesFromEvent(event), vadSource: 'client');
    }
    if (event is Map) {
      final Object? pcm = event['pcm16'] ?? event['bytes'] ?? event['data'];
      final Object? rawSpeech = event['isSpeech'];
      return SparkMicFrame(
        pcm16: _bytesFromEvent(pcm),
        vadSource: (event['vadSource'] as String?) ?? 'unknown',
        vadMode: (event['vadMode'] as String?) ?? '',
        isSpeech: rawSpeech is bool ? rawSpeech : null,
      );
    }
    throw StateError('Unexpected microphone frame type: ${event.runtimeType}');
  }

  final Uint8List pcm16;
  final bool? isSpeech;
  final String vadSource;
  final String vadMode;
}

class SparkAudioBridge {
  static const MethodChannel _methodChannel = MethodChannel('spark/audio');
  static const EventChannel _micChannel = EventChannel('spark/mic');

  Stream<SparkMicFrame>? _micFrames;

  Stream<SparkMicFrame> get micFrames {
    return _micFrames ??= _micChannel.receiveBroadcastStream().map(
      SparkMicFrame.fromEvent,
    );
  }

  Future<bool> requestMicrophonePermission() async {
    return await _methodChannel.invokeMethod<bool>('requestRecordPermission') ??
        false;
  }

  Future<bool> startRecording({
    required int sampleRate,
    required int frameMs,
  }) async {
    return await _methodChannel.invokeMethod<bool>('startRecording', {
          'sampleRate': sampleRate,
          'frameMs': frameMs,
        }) ??
        false;
  }

  Future<Map<String, dynamic>> recordingStatus() async {
    final Object? value = await _methodChannel.invokeMethod<Object?>(
      'recordingStatus',
    );
    if (value is Map) {
      return value.cast<String, dynamic>();
    }
    return const <String, dynamic>{};
  }

  Future<Map<String, dynamic>> stopRecording() async {
    final Object? value = await _methodChannel.invokeMethod<Object?>(
      'stopRecording',
    );
    if (value is Map) {
      return value.cast<String, dynamic>();
    }
    return const <String, dynamic>{};
  }

  Future<bool> startPlayback({required int sampleRate, int? sessionId}) async {
    final Map<String, Object?> arguments = <String, Object?>{
      'sampleRate': sampleRate,
    };
    if (sessionId != null) {
      arguments['sessionId'] = sessionId;
    }
    return await _methodChannel.invokeMethod<bool>(
          'startPlayback',
          arguments,
        ) ??
        false;
  }

  Future<void> writePlayback(Uint8List bytes, {int? sessionId}) async {
    if (bytes.isEmpty) {
      return;
    }
    final Map<String, Object?> arguments = <String, Object?>{'bytes': bytes};
    if (sessionId != null) {
      arguments['sessionId'] = sessionId;
    }
    await _methodChannel.invokeMethod<void>('writePlayback', arguments);
  }

  Future<Map<String, dynamic>> finishPlaybackStream({
    int? sessionId,
    int timeoutMs = 30000,
  }) async {
    final Map<String, Object?> arguments = <String, Object?>{
      'timeoutMs': timeoutMs,
    };
    if (sessionId != null) {
      arguments['sessionId'] = sessionId;
    }
    final Object? value = await _methodChannel.invokeMethod<Object?>(
      'finishPlaybackStream',
      arguments,
    );
    if (value is Map) {
      return value.cast<String, dynamic>();
    }
    return const <String, dynamic>{};
  }

  Future<Map<String, dynamic>> playbackStatus() async {
    final Object? value = await _methodChannel.invokeMethod<Object?>(
      'playbackStatus',
    );
    if (value is Map) {
      return value.cast<String, dynamic>();
    }
    return const <String, dynamic>{};
  }

  Future<Map<String, dynamic>> playDiagnosticTone({
    int sampleRate = 24000,
    int durationMs = 650,
    double frequency = 660,
    double volume = 0.35,
  }) async {
    final Object? value = await _methodChannel
        .invokeMethod<Object?>('playDiagnosticTone', <String, Object?>{
          'sampleRate': sampleRate,
          'durationMs': durationMs,
          'frequency': frequency,
          'volume': volume,
        });
    if (value is Map) {
      return value.cast<String, dynamic>();
    }
    return const <String, dynamic>{};
  }

  Future<void> stopPlayback({int? sessionId}) async {
    final Map<String, Object?> arguments = <String, Object?>{};
    if (sessionId != null) {
      arguments['sessionId'] = sessionId;
    }
    await _methodChannel.invokeMethod<void>('stopPlayback', arguments);
  }
}

Uint8List _bytesFromEvent(Object? event) {
  if (event is Uint8List) {
    return event;
  }
  if (event is List<int>) {
    return Uint8List.fromList(event);
  }
  throw StateError('Unexpected microphone PCM type: ${event.runtimeType}');
}
