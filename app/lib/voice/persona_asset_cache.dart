import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:path_provider/path_provider.dart';

const String storyVaultVoiceServerBaseUrl = 'https://voice.photovault.live';

class PersonaAssetPrefetchProgress {
  const PersonaAssetPrefetchProgress({
    required this.message,
    required this.completedAssets,
    required this.totalAssets,
  });

  final String message;
  final int completedAssets;
  final int totalAssets;

  double get fraction {
    if (totalAssets <= 0) {
      return 0;
    }
    return (completedAssets / totalAssets).clamp(0.0, 1.0);
  }
}

class PersonaAssetPrefetchResult {
  const PersonaAssetPrefetchResult({
    required this.personaCount,
    required this.cachedAssetCount,
  });

  final int personaCount;
  final int cachedAssetCount;
}

class PersonaAssetCache {
  const PersonaAssetCache({this.serverBaseUrl = storyVaultVoiceServerBaseUrl});

  final String serverBaseUrl;

  Future<PersonaAssetPrefetchResult> prefetchAll({
    void Function(PersonaAssetPrefetchProgress progress)? onProgress,
    bool Function()? shouldCancel,
  }) async {
    final Uri baseUri = Uri.parse(serverBaseUrl);
    final HttpClient client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 8);
    try {
      final Uri personasUri = _backendUri('/api/personas', baseUri);
      final HttpClientRequest request = await client.getUrl(personasUri);
      final HttpClientResponse response = await request.close();
      final String body = await response.transform(utf8.decoder).join();
      if (response.statusCode != HttpStatus.ok) {
        throw HttpException('HTTP ${response.statusCode}: $body');
      }
      final Object? decoded = jsonDecode(body);
      if (decoded is! Map<String, dynamic>) {
        throw const FormatException('Persona endpoint must return an object.');
      }
      final List<_PersonaAssetRecord> personas =
          ((decoded['personas'] as List<dynamic>?) ?? const <dynamic>[])
              .whereType<Map<String, dynamic>>()
              .map(_PersonaAssetRecord.fromJson)
              .toList(growable: false);
      final List<_PersonaAssetDownload> downloads = <_PersonaAssetDownload>[
        for (final _PersonaAssetRecord persona in personas) ...persona.assets,
      ];
      final Directory cacheDir = await _cacheDirectory();
      var completed = 0;
      var cached = 0;
      onProgress?.call(
        PersonaAssetPrefetchProgress(
          message: 'Preparing storytellers for Chat.',
          completedAssets: 0,
          totalAssets: downloads.length,
        ),
      );
      for (final _PersonaAssetDownload asset in downloads) {
        _throwIfCancelled(shouldCancel);
        final bool available = await _ensureAsset(
          client,
          cacheDir: cacheDir,
          baseUri: baseUri,
          asset: asset,
        );
        if (available) {
          cached += 1;
        }
        completed += 1;
        onProgress?.call(
          PersonaAssetPrefetchProgress(
            message: _messageFor(asset),
            completedAssets: completed,
            totalAssets: downloads.length,
          ),
        );
      }
      return PersonaAssetPrefetchResult(
        personaCount: personas.length,
        cachedAssetCount: cached,
      );
    } finally {
      client.close(force: true);
    }
  }

  Future<bool> _ensureAsset(
    HttpClient client, {
    required Directory cacheDir,
    required Uri baseUri,
    required _PersonaAssetDownload asset,
  }) async {
    if (asset.url.isEmpty) {
      return false;
    }
    final Uri assetUri = _backendUri(asset.url, baseUri);
    final File destination = File('${cacheDir.path}/${asset.fileName}');
    if (await _isUsableCachedFile(destination, asset)) {
      return true;
    }
    try {
      final HttpClientRequest request = await client.getUrl(assetUri);
      final HttpClientResponse response = await request.close();
      if (response.statusCode != HttpStatus.ok) {
        return false;
      }
      final String fileName = asset.fileNameWithResponseExtension(
        _extensionFromResponse(response, assetUri),
      );
      final File file = File('${cacheDir.path}/$fileName');
      final Uint8List bytes = Uint8List.fromList(
        await response.expand((List<int> chunk) => chunk).toList(),
      );
      if (bytes.isEmpty) {
        return false;
      }
      await file.writeAsBytes(bytes, flush: true);
      if (asset.sha256.isNotEmpty && await _sha256(file) != asset.sha256) {
        await file.delete();
        return false;
      }
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<bool> _isUsableCachedFile(
    File destination,
    _PersonaAssetDownload asset,
  ) async {
    final List<File> candidates = asset.kind == _PersonaAssetKind.voice
        ? <File>[
            destination,
            File('${destination.path}.wave'),
            File(destination.path.replaceFirst(RegExp(r'\.wav$'), '.wave')),
          ]
        : <File>[destination];
    for (final File candidate in candidates) {
      if (!await candidate.exists() || await candidate.length() <= 0) {
        continue;
      }
      if (asset.sha256.isNotEmpty && await _sha256(candidate) != asset.sha256) {
        continue;
      }
      return true;
    }
    return false;
  }

  Future<Directory> _cacheDirectory() async {
    final Directory documents = await getApplicationDocumentsDirectory();
    final Directory cacheDir = Directory('${documents.path}/persona_cache');
    if (!await cacheDir.exists()) {
      await cacheDir.create(recursive: true);
    }
    return cacheDir;
  }

  Uri _backendUri(String value, Uri baseUri) {
    final Uri parsed = Uri.parse(value);
    if (parsed.hasScheme) {
      return parsed;
    }
    return baseUri.resolve(value);
  }

  String _messageFor(_PersonaAssetDownload asset) {
    return switch (asset.kind) {
      _PersonaAssetKind.thumbnail => 'Saving storyteller thumbnails.',
      _PersonaAssetKind.portrait => 'Saving storyteller portraits.',
      _PersonaAssetKind.voice => 'Saving storyteller voices.',
    };
  }

  String _extensionFromResponse(HttpClientResponse response, Uri uri) {
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
    final String path = uri.path.toLowerCase();
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

  Future<String> _sha256(File file) async {
    return (await crypto.sha256.bind(file.openRead()).first).toString();
  }

  void _throwIfCancelled(bool Function()? shouldCancel) {
    if (shouldCancel?.call() == true) {
      throw StateError('Persona setup was skipped.');
    }
  }
}

class _PersonaAssetRecord {
  const _PersonaAssetRecord({
    required this.id,
    required this.assetVersion,
    required this.thumbnailUrl,
    required this.portraitUrl,
    required this.voiceSampleUrl,
    required this.voiceAssetSha256,
    required this.voiceLibraryId,
  });

  factory _PersonaAssetRecord.fromJson(Map<String, dynamic> json) {
    final String id =
        (json['id'] as String?) ?? (json['name'] as String?) ?? 'spark';
    final String voiceAssetSha256 =
        (json['voice_asset_sha256'] as String?)?.trim().toLowerCase() ?? '';
    return _PersonaAssetRecord(
      id: id,
      assetVersion: (json['asset_version'] as String?) ?? '0',
      thumbnailUrl: (json['thumbnail_url'] as String?) ?? '',
      portraitUrl: (json['portrait_url'] as String?) ?? '',
      voiceSampleUrl:
          (json['voice_sample_url'] as String?) ??
          (voiceAssetSha256.isNotEmpty
              ? '/api/tts-assets/personas/$id/voice-sample'
              : ''),
      voiceAssetSha256: voiceAssetSha256,
      voiceLibraryId: (json['voice_library_id'] as String?) ?? '',
    );
  }

  final String id;
  final String assetVersion;
  final String thumbnailUrl;
  final String portraitUrl;
  final String voiceSampleUrl;
  final String voiceAssetSha256;
  final String voiceLibraryId;

  String get voiceCacheKey {
    if (voiceAssetSha256.isNotEmpty) {
      return voiceAssetSha256;
    }
    if (voiceLibraryId.isNotEmpty) {
      return '${voiceLibraryId}_$assetVersion';
    }
    return assetVersion;
  }

  List<_PersonaAssetDownload> get assets {
    return <_PersonaAssetDownload>[
      if (thumbnailUrl.isNotEmpty)
        _PersonaAssetDownload(
          kind: _PersonaAssetKind.thumbnail,
          url: thumbnailUrl,
          fileName: '${_safeCacheToken('${id}_${assetVersion}_thumbnail')}.img',
        ),
      if (portraitUrl.isNotEmpty)
        _PersonaAssetDownload(
          kind: _PersonaAssetKind.portrait,
          url: portraitUrl,
          fileName: '${_safeCacheToken('${id}_${assetVersion}_portrait')}.img',
        ),
      if (voiceSampleUrl.isNotEmpty)
        _PersonaAssetDownload(
          kind: _PersonaAssetKind.voice,
          url: voiceSampleUrl,
          fileName:
              '${_safeCacheToken('${id}_${voiceCacheKey}_voice_sample')}.wav',
          sha256: voiceAssetSha256,
        ),
    ];
  }
}

enum _PersonaAssetKind { thumbnail, portrait, voice }

class _PersonaAssetDownload {
  const _PersonaAssetDownload({
    required this.kind,
    required this.url,
    required this.fileName,
    this.sha256 = '',
  });

  final _PersonaAssetKind kind;
  final String url;
  final String fileName;
  final String sha256;

  String fileNameWithResponseExtension(String responseExtension) {
    if (kind != _PersonaAssetKind.voice) {
      return fileName;
    }
    return fileName.replaceFirst(RegExp(r'\.[^.]+$'), responseExtension);
  }
}

String _safeCacheToken(String raw) {
  return raw.replaceAll(RegExp(r'[^a-zA-Z0-9._-]'), '_');
}
