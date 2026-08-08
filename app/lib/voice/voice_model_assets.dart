import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart' as crypto;
import 'package:path_provider/path_provider.dart';

const String voiceModelManifestUrl = String.fromEnvironment(
  'STORYVAULT_VOICE_MODEL_MANIFEST_URL',
  defaultValue: 'https://voice.photovault.live/api/mobile-voice-assets',
);
const String voiceModelPackId = 'storyvault-mobile-voice-v1';
const String pocketTtsModelId = 'sherpa-onnx-pocket-tts-int8-2026-01-26';
const String whisperAsrModelId = 'sherpa-onnx-whisper-tiny.en-int8';
const String pocketTtsRuntimeId = 'sherpa_onnx_1.13.3';
const String pocketTtsDefaultReferenceAudio =
    'sherpa-onnx-pocket-tts-int8-2026-01-26/test_wavs/bria_12s.wav';

const List<String> _downloadStatusMessages = <String>[
  'Downloading voice assets',
  'Checking device compatibility',
  'Polishing your device',
  'Preparing clear listening',
  'Warming the storyteller voice',
  'Tuning the voice clone',
  'Saving voice files for next time',
  'Almost ready for Talk',
];

class VoiceModelAssetPaths {
  const VoiceModelAssetPaths({
    required this.rootDir,
    required this.pocketTtsModelDir,
    required this.whisperAsrModelDir,
    required this.defaultReferenceAudioPath,
  });

  final String rootDir;
  final String pocketTtsModelDir;
  final String whisperAsrModelDir;
  final String defaultReferenceAudioPath;
}

class VoiceModelAssetProgress {
  const VoiceModelAssetProgress({
    required this.message,
    required this.fileName,
    required this.fileIndex,
    required this.fileCount,
    required this.downloadedBytes,
    required this.totalBytes,
    required this.cached,
  });

  final String message;
  final String fileName;
  final int fileIndex;
  final int fileCount;
  final int downloadedBytes;
  final int totalBytes;
  final bool cached;

  double get fraction {
    if (totalBytes <= 0) {
      return fileCount <= 0 ? 0 : fileIndex / fileCount;
    }
    return (downloadedBytes / totalBytes).clamp(0.0, 1.0);
  }
}

class VoiceModelAssetStore {
  VoiceModelAssetStore._();

  static final VoiceModelAssetStore instance = VoiceModelAssetStore._();

  Future<VoiceModelAssetPaths>? _activeEnsure;

  Future<VoiceModelAssetPaths> ensureVoiceModelPack({
    Uri? manifestUri,
    void Function(VoiceModelAssetProgress progress)? onProgress,
    bool Function()? shouldCancel,
  }) {
    final Future<VoiceModelAssetPaths>? active = _activeEnsure;
    if (active != null) {
      return active;
    }
    final Future<VoiceModelAssetPaths> next = _ensureVoiceModelPack(
      manifestUri: manifestUri ?? Uri.parse(voiceModelManifestUrl),
      onProgress: onProgress,
      shouldCancel: shouldCancel,
    );
    _activeEnsure = next;
    return next.whenComplete(() {
      if (identical(_activeEnsure, next)) {
        _activeEnsure = null;
      }
    });
  }

  Future<VoiceModelAssetPaths> pathsIfInstalled() async {
    final Directory root = await _voiceAssetRoot();
    return _pathsForRoot(root);
  }

  Future<VoiceModelAssetPaths> _ensureVoiceModelPack({
    required Uri manifestUri,
    void Function(VoiceModelAssetProgress progress)? onProgress,
    bool Function()? shouldCancel,
  }) async {
    _throwIfCancelled(shouldCancel);
    final HttpClient client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 12);
    try {
      final Map<String, dynamic> manifest = await _fetchManifest(
        client,
        manifestUri,
      );
      final List<_VoiceModelAssetFile> files = _readFiles(
        manifest,
        manifestUri,
      );
      final Directory root = await _voiceAssetRoot();
      if (!await root.exists()) {
        await root.create(recursive: true);
      }

      final Map<String, dynamic> previousState = await _readState(root);
      final int totalBytes = files.fold<int>(
        0,
        (int sum, _VoiceModelAssetFile file) => sum + file.sizeBytes,
      );
      var completedBytes = 0;
      final Stopwatch stopwatch = Stopwatch()..start();
      for (var index = 0; index < files.length; index += 1) {
        _throwIfCancelled(shouldCancel);
        final _VoiceModelAssetFile file = files[index];
        final File destination = File('${root.path}/${file.relativePath}');
        final bool cached = await _isCached(destination, file, previousState);
        if (cached) {
          completedBytes += file.sizeBytes;
          onProgress?.call(
            _progress(
              file: file,
              fileIndex: index + 1,
              fileCount: files.length,
              completedBytes: completedBytes,
              totalBytes: totalBytes,
              stopwatch: stopwatch,
              cached: true,
            ),
          );
          continue;
        }

        await destination.parent.create(recursive: true);
        await _downloadFile(
          client,
          file,
          destination,
          completedBytes: completedBytes,
          totalBytes: totalBytes,
          fileIndex: index + 1,
          fileCount: files.length,
          stopwatch: stopwatch,
          onProgress: onProgress,
          shouldCancel: shouldCancel,
        );
        final String actualSha = await _sha256(destination);
        if (actualSha != file.sha256) {
          try {
            await destination.delete();
          } catch (_) {
            // A stale bad file will be retried on the next setup attempt.
          }
          throw StateError('Downloaded voice asset failed checksum.');
        }
        completedBytes += file.sizeBytes;
        onProgress?.call(
          _progress(
            file: file,
            fileIndex: index + 1,
            fileCount: files.length,
            completedBytes: completedBytes,
            totalBytes: totalBytes,
            stopwatch: stopwatch,
            cached: false,
          ),
        );
      }
      await _writeState(root, manifest, files);
      return _pathsForRoot(root);
    } finally {
      client.close(force: true);
    }
  }

  Future<Map<String, dynamic>> _fetchManifest(
    HttpClient client,
    Uri manifestUri,
  ) async {
    final HttpClientRequest request = await client.getUrl(manifestUri);
    final HttpClientResponse response = await request.close();
    final String body = await response.transform(utf8.decoder).join();
    if (response.statusCode != HttpStatus.ok) {
      throw HttpException(
        'HTTP ${response.statusCode}: $body',
        uri: manifestUri,
      );
    }
    final Object? decoded = jsonDecode(body);
    if (decoded is! Map<String, dynamic>) {
      throw const FormatException(
        'Voice model manifest must be a JSON object.',
      );
    }
    if ((decoded['pack_id'] as String?)?.trim() != voiceModelPackId) {
      throw const FormatException('Unexpected voice model pack id.');
    }
    return decoded;
  }

  List<_VoiceModelAssetFile> _readFiles(
    Map<String, dynamic> manifest,
    Uri manifestUri,
  ) {
    final List<dynamic> rawFiles =
        manifest['files'] as List<dynamic>? ?? const <dynamic>[];
    final List<_VoiceModelAssetFile> files = <_VoiceModelAssetFile>[];
    for (final Object? rawFile in rawFiles) {
      if (rawFile is! Map<String, dynamic>) {
        continue;
      }
      final String relativePath = (rawFile['relative_path'] as String?) ?? '';
      final String sha256 = (rawFile['sha256'] as String?) ?? '';
      final int sizeBytes = (rawFile['size_bytes'] as num?)?.toInt() ?? 0;
      final String url = (rawFile['url'] as String?) ?? '';
      if (relativePath.isEmpty ||
          relativePath.startsWith('/') ||
          relativePath.contains('..') ||
          sha256.length != 64 ||
          sizeBytes <= 0 ||
          url.isEmpty) {
        continue;
      }
      files.add(
        _VoiceModelAssetFile(
          relativePath: relativePath,
          sha256: sha256.toLowerCase(),
          sizeBytes: sizeBytes,
          uri: manifestUri.resolve(url),
        ),
      );
    }
    final Set<String> paths = files
        .map((_VoiceModelAssetFile file) => file.relativePath)
        .toSet();
    final bool hasPocket = paths.any(
      (String path) => path.startsWith('$pocketTtsModelId/'),
    );
    final bool hasWhisper = paths.any(
      (String path) => path.startsWith('$whisperAsrModelId/'),
    );
    if (!hasPocket || !hasWhisper) {
      throw const FormatException(
        'Voice model manifest must include PocketTTS and Whisper assets.',
      );
    }
    return files;
  }

  Future<bool> _isCached(
    File destination,
    _VoiceModelAssetFile file,
    Map<String, dynamic> previousState,
  ) async {
    if (!await destination.exists() ||
        await destination.length() != file.sizeBytes) {
      return false;
    }
    final Map<String, dynamic>? stateFiles =
        previousState['files'] is Map<String, dynamic>
        ? previousState['files'] as Map<String, dynamic>
        : null;
    if (previousState['pack_id'] == voiceModelPackId &&
        stateFiles?[file.relativePath] == file.sha256) {
      return true;
    }
    return await _sha256(destination) == file.sha256;
  }

  Future<void> _downloadFile(
    HttpClient client,
    _VoiceModelAssetFile file,
    File destination, {
    required int completedBytes,
    required int totalBytes,
    required int fileIndex,
    required int fileCount,
    required Stopwatch stopwatch,
    required void Function(VoiceModelAssetProgress progress)? onProgress,
    required bool Function()? shouldCancel,
  }) async {
    final File partial = File('${destination.path}.part');
    var partialBytes = 0;
    if (await partial.exists()) {
      final int existingPartialBytes = await partial.length();
      if (existingPartialBytes > 0 && existingPartialBytes < file.sizeBytes) {
        partialBytes = existingPartialBytes;
      } else {
        await partial.delete();
      }
    }
    HttpClientRequest request = await client.getUrl(file.uri);
    if (partialBytes > 0) {
      request.headers.set(HttpHeaders.rangeHeader, 'bytes=$partialBytes-');
    }
    HttpClientResponse response = await request.close();
    IOSink sink;
    var downloadedThisFile = partialBytes;
    if (response.statusCode == HttpStatus.partialContent && partialBytes > 0) {
      sink = partial.openWrite(mode: FileMode.append);
    } else {
      partialBytes = 0;
      downloadedThisFile = 0;
      sink = partial.openWrite();
    }
    if (response.statusCode != HttpStatus.ok &&
        response.statusCode != HttpStatus.partialContent) {
      await sink.close();
      throw HttpException('HTTP ${response.statusCode}', uri: file.uri);
    }
    try {
      await for (final List<int> chunk in response) {
        _throwIfCancelled(shouldCancel);
        sink.add(chunk);
        downloadedThisFile += chunk.length;
        onProgress?.call(
          _progress(
            file: file,
            fileIndex: fileIndex,
            fileCount: fileCount,
            completedBytes: completedBytes + downloadedThisFile,
            totalBytes: totalBytes,
            stopwatch: stopwatch,
            cached: false,
          ),
        );
      }
    } finally {
      await sink.close();
    }
    if (downloadedThisFile != file.sizeBytes) {
      throw StateError('Downloaded voice asset was incomplete.');
    }
    if (await destination.exists()) {
      await destination.delete();
    }
    await partial.rename(destination.path);
  }

  VoiceModelAssetProgress _progress({
    required _VoiceModelAssetFile file,
    required int fileIndex,
    required int fileCount,
    required int completedBytes,
    required int totalBytes,
    required Stopwatch stopwatch,
    required bool cached,
  }) {
    final int seconds = stopwatch.elapsed.inSeconds;
    final int messageIndex = (seconds ~/ 7)
        .clamp(0, _downloadStatusMessages.length - 1)
        .toInt();
    final String baseMessage = _downloadStatusMessages[messageIndex];
    final String fileName = file.relativePath.split('/').last;
    return VoiceModelAssetProgress(
      message: cached ? 'Checking downloaded voice assets' : baseMessage,
      fileName: fileName,
      fileIndex: fileIndex,
      fileCount: fileCount,
      downloadedBytes: completedBytes.clamp(0, totalBytes).toInt(),
      totalBytes: totalBytes,
      cached: cached,
    );
  }

  Future<Directory> _voiceAssetRoot() async {
    final Directory supportDir = await getApplicationSupportDirectory();
    return Directory('${supportDir.path}/voice_model_assets/$voiceModelPackId');
  }

  VoiceModelAssetPaths _pathsForRoot(Directory root) {
    return VoiceModelAssetPaths(
      rootDir: root.path,
      pocketTtsModelDir: '${root.path}/$pocketTtsModelId',
      whisperAsrModelDir: '${root.path}/$whisperAsrModelId',
      defaultReferenceAudioPath: '${root.path}/$pocketTtsDefaultReferenceAudio',
    );
  }

  Future<Map<String, dynamic>> _readState(Directory root) async {
    final File state = File('${root.path}/manifest_state.json');
    if (!await state.exists()) {
      return const <String, dynamic>{};
    }
    try {
      final Object? decoded = jsonDecode(await state.readAsString());
      if (decoded is Map<String, dynamic>) {
        return decoded;
      }
    } catch (_) {
      // A corrupt state file only forces checksum verification.
    }
    return const <String, dynamic>{};
  }

  Future<void> _writeState(
    Directory root,
    Map<String, dynamic> manifest,
    List<_VoiceModelAssetFile> files,
  ) async {
    final File state = File('${root.path}/manifest_state.json');
    final Map<String, String> fileHashes = <String, String>{
      for (final _VoiceModelAssetFile file in files)
        file.relativePath: file.sha256,
    };
    await state.writeAsString(
      const JsonEncoder.withIndent('  ').convert(<String, Object?>{
        'pack_id': manifest['pack_id'],
        'version': manifest['version'],
        'files': fileHashes,
      }),
      flush: true,
    );
  }

  Future<String> _sha256(File file) async {
    return (await crypto.sha256.bind(file.openRead()).first).toString();
  }

  void _throwIfCancelled(bool Function()? shouldCancel) {
    if (shouldCancel?.call() == true) {
      throw StateError('Voice model setup was skipped.');
    }
  }
}

class _VoiceModelAssetFile {
  const _VoiceModelAssetFile({
    required this.relativePath,
    required this.sha256,
    required this.sizeBytes,
    required this.uri,
  });

  final String relativePath;
  final String sha256;
  final int sizeBytes;
  final Uri uri;
}
