import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter/services.dart';

import '../models/content_item.dart';
import '../models/playlist.dart';
import 'deployed_content_repository.dart';

typedef UsbPlaylistExportProgressCallback =
    void Function(UsbPlaylistExportProgress progress);

enum UsbPlaylistExportStage {
  preparing,
  clearing,
  downloading,
  copying,
  finalizing,
  complete,
  cancelled,
}

class UsbPlaylistExportCancelToken {
  bool _cancelled = false;

  bool get isCancelled => _cancelled;

  void cancel() {
    _cancelled = true;
  }
}

class UsbStorageDeviceTarget {
  final String rootUri;
  final String label;
  final int capacity;
  final int freeSpace;

  const UsbStorageDeviceTarget({
    required this.rootUri,
    required this.label,
    required this.capacity,
    required this.freeSpace,
  });

  String get freeSpaceLabel => _formatBytes(freeSpace);

  static String _formatBytes(int bytes) {
    if (bytes <= 0) {
      return 'storage ready';
    }
    const units = ['B', 'KB', 'MB', 'GB', 'TB'];
    var value = bytes.toDouble();
    var unitIndex = 0;
    while (value >= 1024 && unitIndex < units.length - 1) {
      value /= 1024;
      unitIndex += 1;
    }
    final formatted = value >= 10
        ? value.toStringAsFixed(1)
        : value.toStringAsFixed(2);
    return '$formatted ${units[unitIndex]} free';
  }
}

class UsbPlaylistExportProgress {
  final String message;
  final int completedItems;
  final int totalItems;
  final String? deviceLabel;
  final UsbPlaylistExportStage stage;

  const UsbPlaylistExportProgress({
    required this.message,
    required this.completedItems,
    required this.totalItems,
    this.deviceLabel,
    this.stage = UsbPlaylistExportStage.preparing,
  });
}

class UsbPlaylistExportResult {
  final String playlistTitle;
  final String? rootUri;
  final String? deviceLabel;
  final int copied;
  final int skipped;
  final int repaired;
  final int failed;
  final int totalItems;
  final int totalBytes;
  final bool cancelled;
  final bool usbIoFailure;
  final List<String> messages;

  const UsbPlaylistExportResult({
    required this.playlistTitle,
    required this.rootUri,
    required this.deviceLabel,
    required this.copied,
    required this.skipped,
    required this.repaired,
    required this.failed,
    required this.totalItems,
    required this.totalBytes,
    required this.cancelled,
    this.usbIoFailure = false,
    required this.messages,
  });

  String get summary {
    if (cancelled) {
      return 'Copy stopped safely.';
    }
    if (failed == 0) {
      return 'Playlist copied successfully.';
    }
    if (usbIoFailure) {
      return 'Something went wrong while writing to the device.';
    }
    return 'Some playlist files could not be downloaded. Try again.';
  }
}

class UsbPlaylistExporter {
  UsbPlaylistExporter._();

  static final UsbPlaylistExporter instance = UsbPlaylistExporter._();

  // Parent-triggered MP3 export has to support very simple USB MP3 players.
  // Those devices often only read root-level numbered files, so Android writes
  // through direct USB Host when possible and iOS writes to the root folder the
  // parent selects in Files. The app never formats drives or asks for broad
  // phone-storage access.
  static const MethodChannel _channel = MethodChannel('storyvault/usb_export');
  static const String _manifestFileName = 'storyvault_manifest.json';
  static final RegExp _numberedAudioName = RegExp(
    r'^(\d{3,})_.*\.(mp3|wav)$',
    caseSensitive: false,
  );

  bool get supported => Platform.isAndroid || Platform.isIOS;

  Future<UsbStorageDeviceTarget?> openStorageDevice() async {
    if (!supported) {
      throw UnsupportedError(
        'USB playlist export is available on Android and iOS only.',
      );
    }
    final rootUri = await _selectRoot();
    if (rootUri == null || rootUri.isEmpty) {
      return null;
    }
    if (!_isSupportedTargetRoot(rootUri)) {
      throw UnsupportedError(
        'Connect a StoryVault USB storage device and try again.',
      );
    }
    final deviceInfo = await _getDeviceInfo(rootUri);
    return UsbStorageDeviceTarget(
      rootUri: rootUri,
      label: deviceInfo.label,
      capacity: deviceInfo.capacity,
      freeSpace: deviceInfo.freeSpace,
    );
  }

  Future<UsbPlaylistExportResult> exportPlaylist(
    Playlist playlist, {
    required UsbStorageDeviceTarget target,
    UsbPlaylistExportProgressCallback? onProgress,
    UsbPlaylistExportCancelToken? cancelToken,
  }) async {
    if (!supported) {
      throw UnsupportedError(
        'USB playlist export is available on Android and iOS only.',
      );
    }
    if (playlist.items.isEmpty) {
      throw StateError('This playlist is empty.');
    }

    final rootUri = target.rootUri;
    if (!_isSupportedTargetRoot(rootUri)) {
      throw UnsupportedError(
        'Connect a StoryVault USB storage device and try again.',
      );
    }
    final deviceLabel = target.label;
    var cancelled = false;
    onProgress?.call(
      UsbPlaylistExportProgress(
        message: 'Writing to $deviceLabel.',
        completedItems: 0,
        totalItems: playlist.items.length,
        deviceLabel: deviceLabel,
        stage: UsbPlaylistExportStage.preparing,
      ),
    );
    final messages = <String>[];
    var copied = 0;
    var skipped = 0;
    var repaired = 0;
    var failed = 0;
    var usbIoFailure = false;
    var totalBytes = 0;
    final preparedItems = <String, _PreparedUsbExportItem>{};
    for (var i = 0; i < playlist.items.length; i += 1) {
      if (cancelToken?.isCancelled ?? false) {
        cancelled = true;
        break;
      }
      final content = playlist.items[i].content;
      final contentKey = _contentKey(content);
      onProgress?.call(
        UsbPlaylistExportProgress(
          message: 'Downloading ${i + 1}/${playlist.items.length}.',
          completedItems: i,
          totalItems: playlist.items.length,
          deviceLabel: deviceLabel,
          stage: UsbPlaylistExportStage.downloading,
        ),
      );
      try {
        final downloaded = await DeployedContentRepository.instance
            .ensureDownloaded(content);
        final sourcePath = downloaded.audioSrc.trim();
        final sourceFile = File(sourcePath);
        if (sourcePath.isEmpty || !await sourceFile.exists()) {
          throw FileSystemException('Downloaded MP3 is missing', sourcePath);
        }
        preparedItems[contentKey] = _PreparedUsbExportItem(
          sourcePath: sourcePath,
          bytes: await sourceFile.length(),
          sha256: await _sha256(sourceFile),
        );
      } catch (_) {
        failed += 1;
        messages.add('Could not prepare "${content.displayTitle}".');
      }
    }
    if (cancelled || failed > 0) {
      onProgress?.call(
        UsbPlaylistExportProgress(
          message: cancelled
              ? 'Copy stopped safely.'
              : 'Could not prepare playlist.',
          completedItems: preparedItems.length,
          totalItems: playlist.items.length,
          deviceLabel: deviceLabel,
          stage: cancelled
              ? UsbPlaylistExportStage.cancelled
              : UsbPlaylistExportStage.downloading,
        ),
      );
      return UsbPlaylistExportResult(
        playlistTitle: playlist.title,
        rootUri: rootUri,
        deviceLabel: deviceLabel,
        copied: 0,
        skipped: 0,
        repaired: 0,
        failed: failed,
        totalItems: playlist.items.length,
        totalBytes: 0,
        cancelled: cancelled,
        usbIoFailure: false,
        messages: List<String>.unmodifiable(messages),
      );
    }
    onProgress?.call(
      UsbPlaylistExportProgress(
        message: 'Preparing device.',
        completedItems: 0,
        totalItems: playlist.items.length,
        deviceLabel: deviceLabel,
        stage: UsbPlaylistExportStage.preparing,
      ),
    );
    final rootFiles = await _listRoot(rootUri);
    var activeRootFiles = rootFiles;
    var rootFileNames = activeRootFiles
        .map((file) => file.name.toLowerCase())
        .toSet();
    final manifestText = await _readTextFile(rootUri, _manifestFileName);
    final hadExistingManifest =
        manifestText != null && manifestText.trim().isNotEmpty;
    final manifest = _manifestFromText(
      manifestText,
      existingRootFiles: rootFiles,
    );
    var manifestFiles = _manifestFiles(manifest);
    final selectedContentKeys = playlist.items
        .map((item) => _contentKey(item.content))
        .toList(growable: false);
    final existingPlaylistId = _manifestPlaylistId(manifest);
    final manifestIsSamePlaylist =
        hadExistingManifest && existingPlaylistId == playlist.id;
    final canAppendCurrentPlaylist =
        manifestIsSamePlaylist &&
        _manifestSequenceIsPrefix(
          manifestFiles: manifestFiles,
          selectedContentKeys: selectedContentKeys,
        );

    if (!hadExistingManifest || !manifestIsSamePlaylist) {
      final reason = !hadExistingManifest
          ? 'Clearing old audio.'
          : 'Clearing old audio for this playlist.';
      onProgress?.call(
        UsbPlaylistExportProgress(
          message: reason,
          completedItems: 0,
          totalItems: playlist.items.length,
          deviceLabel: deviceLabel,
          stage: UsbPlaylistExportStage.clearing,
        ),
      );
      final deleted = await _deleteRootAudioFiles(
        rootUri: rootUri,
        rootFiles: activeRootFiles,
      );
      if (deleted > 0) {
        messages.add('Cleared old audio.');
      }
      activeRootFiles = await _listRoot(rootUri);
      rootFileNames = activeRootFiles
          .map((file) => file.name.toLowerCase())
          .toSet();
      manifest
        ..['playlist_id'] = playlist.id
        ..['playlist_title'] = playlist.title
        ..['files'] = <Map<String, dynamic>>[]
        ..['next_index'] = 1
        ..['last_synced_at'] = _nowIso();
      manifestFiles = _manifestFiles(manifest);
      await _writeManifest(rootUri, manifest);
    } else if (!canAppendCurrentPlaylist) {
      throw StateError(
        'This device already has another version of this playlist. Use a different storage device or clear this one first.',
      );
    } else {
      manifest
        ..['playlist_id'] = playlist.id
        ..['playlist_title'] = playlist.title;
    }

    final manifestByKey = <String, Map<String, dynamic>>{};
    for (final entry in manifestFiles) {
      final key = _entryContentKey(entry);
      if (key.isNotEmpty) {
        manifestByKey[key] = entry;
      }
      final filename = entry['filename']?.toString().trim() ?? '';
      if (filename.isNotEmpty &&
          !rootFileNames.contains(filename.toLowerCase())) {
        entry['status'] = 'missing';
      }
    }

    var nextIndex = max(
      _manifestNextIndex(manifest),
      _nextIndexFromRootFiles(activeRootFiles),
    );
    final usedNames = Set<String>.from(rootFileNames);

    if (!hadExistingManifest && manifestFiles.isEmpty) {
      await _writeManifest(rootUri, manifest);
    }

    for (var i = 0; i < playlist.items.length; i += 1) {
      if (cancelToken?.isCancelled ?? false) {
        cancelled = true;
        break;
      }
      final playlistItem = playlist.items[i];
      final content = playlistItem.content;
      final contentKey = _contentKey(content);
      final label = content.displayTitle;
      onProgress?.call(
        UsbPlaylistExportProgress(
          message: 'Checking ${i + 1}/${playlist.items.length}.',
          completedItems: i,
          totalItems: playlist.items.length,
          deviceLabel: deviceLabel,
          stage: UsbPlaylistExportStage.preparing,
        ),
      );

      try {
        final existingEntry = manifestByKey[contentKey];
        final existingName =
            existingEntry?['filename']?.toString().trim() ?? '';
        final existingFilePresent =
            existingName.isNotEmpty &&
            usedNames.contains(existingName.toLowerCase());
        if (existingEntry != null && existingFilePresent) {
          _attachPlaylist(existingEntry, playlist);
          existingEntry['status'] = 'present';
          skipped += 1;
          continue;
        }

        final prepared = preparedItems[contentKey];
        if (prepared == null) {
          throw FileSystemException('Prepared MP3 is missing');
        }
        final filename = existingEntry == null || existingName.isEmpty
            ? _allocateFilename(
                content,
                nextIndex: nextIndex,
                usedNames: usedNames,
              )
            : existingName;
        if (existingEntry == null || existingName.isEmpty) {
          nextIndex = max(nextIndex, _indexFromFilename(filename) + 1);
        }

        onProgress?.call(
          UsbPlaylistExportProgress(
            message: 'Copying ${i + 1}/${playlist.items.length}.',
            completedItems: i,
            totalItems: playlist.items.length,
            deviceLabel: deviceLabel,
            stage: UsbPlaylistExportStage.copying,
          ),
        );
        final copiedInfo =
            await _copyFileToRoot(
              rootUri: rootUri,
              sourcePath: prepared.sourcePath,
              fileName: filename,
              mimeType: 'audio/mpeg',
            ).catchError((error) {
              usbIoFailure = true;
              throw error;
            });
        final exportedBytes =
            (copiedInfo['bytes'] as num?)?.toInt() ?? prepared.bytes;
        totalBytes += exportedBytes;
        usedNames.add(filename.toLowerCase());

        final exportedEntry = existingEntry ?? <String, dynamic>{};
        exportedEntry
          ..['index'] = _indexFromFilename(filename)
          ..['type'] = content.type
          ..['language'] = content.language
          ..['content_key'] = contentKey
          ..['content_id'] = _contentId(content)
          ..['category'] = content.category
          ..['title'] = content.displayTitle
          ..['filename'] = filename
          ..['bytes'] = exportedBytes
          ..['sha256'] = prepared.sha256
          ..['duration_seconds'] = content.durationSeconds
          ..['exported_at'] = _nowIso()
          ..['status'] = 'present';
        _attachPlaylist(exportedEntry, playlist);
        if (existingEntry == null) {
          manifestFiles.add(exportedEntry);
          manifestByKey[contentKey] = exportedEntry;
          copied += 1;
        } else {
          repaired += 1;
        }
        manifest['next_index'] = nextIndex;
        manifest['last_synced_at'] = _nowIso();
      } catch (error) {
        failed += 1;
        messages.add('Could not copy "$label".');
      }

      onProgress?.call(
        UsbPlaylistExportProgress(
          message: 'Finished ${i + 1}/${playlist.items.length}',
          completedItems: i + 1,
          totalItems: playlist.items.length,
          deviceLabel: deviceLabel,
          stage: UsbPlaylistExportStage.copying,
        ),
      );
      if (cancelToken?.isCancelled ?? false) {
        cancelled = true;
        break;
      }
    }

    onProgress?.call(
      UsbPlaylistExportProgress(
        message: 'Finalizing playlist.',
        completedItems: playlist.items.length,
        totalItems: playlist.items.length,
        deviceLabel: deviceLabel,
        stage: UsbPlaylistExportStage.finalizing,
      ),
    );
    manifest['next_index'] = nextIndex;
    manifest['playlist_id'] = playlist.id;
    manifest['playlist_title'] = playlist.title;
    manifest['playlist_signature'] = _playlistSignature(selectedContentKeys);
    manifest['last_synced_at'] = _nowIso();
    manifest['files'] = manifestFiles
      ..sort(
        (a, b) => ((a['index'] ?? 0) as num).toInt().compareTo(
          ((b['index'] ?? 0) as num).toInt(),
        ),
      );
    await _writeManifest(rootUri, manifest);
    onProgress?.call(
      UsbPlaylistExportProgress(
        message: cancelled
            ? 'Copy stopped safely.'
            : usbIoFailure
            ? 'USB writing did not complete.'
            : (failed == 0 ? 'Playlist copied.' : 'Export finished.'),
        completedItems: cancelled
            ? min(copied + skipped + repaired, playlist.items.length)
            : usbIoFailure
            ? min(copied + skipped + repaired, playlist.items.length)
            : playlist.items.length,
        totalItems: playlist.items.length,
        deviceLabel: deviceLabel,
        stage: cancelled
            ? UsbPlaylistExportStage.cancelled
            : usbIoFailure
            ? UsbPlaylistExportStage.copying
            : UsbPlaylistExportStage.complete,
      ),
    );

    return UsbPlaylistExportResult(
      playlistTitle: playlist.title,
      rootUri: rootUri,
      deviceLabel: deviceLabel,
      copied: copied,
      skipped: skipped,
      repaired: repaired,
      failed: failed,
      totalItems: playlist.items.length,
      totalBytes: totalBytes,
      cancelled: cancelled,
      usbIoFailure: usbIoFailure,
      messages: List<String>.unmodifiable(messages),
    );
  }

  Future<String?> _selectRoot() async {
    return _channel.invokeMethod<String>('selectRoot');
  }

  bool _isSupportedTargetRoot(String rootUri) {
    return rootUri.startsWith('usbms://') || rootUri.startsWith('iosdir://');
  }

  Future<void> releaseDevice(String rootUri) async {
    await _channel.invokeMethod<void>('releaseRoot', {'rootUri': rootUri});
  }

  Future<_UsbDeviceInfo> _getDeviceInfo(String rootUri) async {
    final value = await _channel.invokeMethod<Map<dynamic, dynamic>>(
      'getDeviceInfo',
      {'rootUri': rootUri},
    );
    return _UsbDeviceInfo.fromJson(
      (value ?? const <dynamic, dynamic>{}).cast<String, dynamic>(),
    );
  }

  Future<List<_UsbRootFile>> _listRoot(String rootUri) async {
    final value = await _channel.invokeMethod<List<dynamic>>('listRoot', {
      'rootUri': rootUri,
    });
    return (value ?? const <dynamic>[])
        .whereType<Map<dynamic, dynamic>>()
        .map((entry) => _UsbRootFile.fromJson(entry.cast<String, dynamic>()))
        .where((entry) => entry.name.isNotEmpty)
        .toList(growable: false);
  }

  Future<String?> _readTextFile(String rootUri, String fileName) {
    return _channel.invokeMethod<String>('readTextFile', {
      'rootUri': rootUri,
      'fileName': fileName,
    });
  }

  Future<void> _writeTextFile({
    required String rootUri,
    required String fileName,
    required String text,
  }) async {
    await _channel.invokeMethod<void>('writeTextFile', {
      'rootUri': rootUri,
      'fileName': fileName,
      'text': text,
      'mimeType': 'application/json',
    });
  }

  Future<Map<String, dynamic>> _copyFileToRoot({
    required String rootUri,
    required String sourcePath,
    required String fileName,
    required String mimeType,
  }) async {
    final value = await _channel
        .invokeMethod<Map<dynamic, dynamic>>('copyFileToRoot', {
          'rootUri': rootUri,
          'sourcePath': sourcePath,
          'fileName': fileName,
          'mimeType': mimeType,
        });
    return (value ?? const <dynamic, dynamic>{}).cast<String, dynamic>();
  }

  Future<void> _deleteRootFile({
    required String rootUri,
    required String fileName,
  }) async {
    await _channel.invokeMethod<void>('deleteRootFile', {
      'rootUri': rootUri,
      'fileName': fileName,
    });
  }

  Future<void> _writeManifest(String rootUri, Map<String, dynamic> manifest) {
    return _writeTextFile(
      rootUri: rootUri,
      fileName: _manifestFileName,
      text: const JsonEncoder.withIndent('  ').convert(manifest),
    );
  }

  Map<String, dynamic> _manifestFromText(
    String? text, {
    required List<_UsbRootFile> existingRootFiles,
  }) {
    if (text != null && text.trim().isNotEmpty) {
      try {
        final decoded = jsonDecode(text) as Map<String, dynamic>;
        decoded['schema_version'] = 1;
        decoded['created_by'] = 'StoryVault';
        decoded['files'] = _manifestFiles(decoded);
        decoded['next_index'] = max(
          _manifestNextIndex(decoded),
          _nextIndexFromRootFiles(existingRootFiles),
        );
        return decoded;
      } catch (_) {
        // A malformed manifest is treated as a fresh target, but existing
        // numbered audio files still reserve their indexes.
      }
    }
    final now = _nowIso();
    return <String, dynamic>{
      'schema_version': 1,
      'created_by': 'StoryVault',
      'device_id': _localUuid(),
      'created_at': now,
      'last_synced_at': now,
      'next_index': _nextIndexFromRootFiles(existingRootFiles),
      'files': <Map<String, dynamic>>[],
    };
  }

  List<Map<String, dynamic>> _manifestFiles(Map<String, dynamic> manifest) {
    final files = manifest['files'];
    if (files is! List) {
      final replacement = <Map<String, dynamic>>[];
      manifest['files'] = replacement;
      return replacement;
    }
    final normalized = files
        .whereType<Map<dynamic, dynamic>>()
        .map((entry) => entry.cast<String, dynamic>())
        .toList(growable: true);
    manifest['files'] = normalized;
    return normalized;
  }

  String _manifestPlaylistId(Map<String, dynamic> manifest) {
    return (manifest['playlist_id'] ?? '').toString().trim();
  }

  bool _manifestSequenceIsPrefix({
    required List<Map<String, dynamic>> manifestFiles,
    required List<String> selectedContentKeys,
  }) {
    final existingKeys = List<Map<String, dynamic>>.from(manifestFiles)
      ..sort(
        (a, b) => ((a['index'] ?? 0) as num).toInt().compareTo(
          ((b['index'] ?? 0) as num).toInt(),
        ),
      );
    if (existingKeys.length > selectedContentKeys.length) {
      return false;
    }
    for (var i = 0; i < existingKeys.length; i += 1) {
      if (_entryContentKey(existingKeys[i]) != selectedContentKeys[i]) {
        return false;
      }
    }
    return true;
  }

  String _playlistSignature(List<String> selectedContentKeys) {
    return crypto.sha1
        .convert(utf8.encode(selectedContentKeys.join('\n')))
        .toString();
  }

  Future<int> _deleteRootAudioFiles({
    required String rootUri,
    required List<_UsbRootFile> rootFiles,
  }) async {
    var deleted = 0;
    for (final file in rootFiles) {
      if (!_isRootAudioFile(file.name)) {
        continue;
      }
      await _deleteRootFile(rootUri: rootUri, fileName: file.name);
      deleted += 1;
    }
    return deleted;
  }

  bool _isRootAudioFile(String fileName) {
    final lower = fileName.trim().toLowerCase();
    return lower.endsWith('.mp3') || lower.endsWith('.wav');
  }

  int _manifestNextIndex(Map<String, dynamic> manifest) {
    final explicit = (manifest['next_index'] as num?)?.toInt() ?? 1;
    final files = _manifestFiles(manifest);
    final maxEntryIndex = files.fold<int>(0, (maxIndex, entry) {
      final index =
          (entry['index'] as num?)?.toInt() ??
          _indexFromFilename(entry['filename']?.toString() ?? '');
      return max(maxIndex, index);
    });
    return max(1, max(explicit, maxEntryIndex + 1));
  }

  int _nextIndexFromRootFiles(List<_UsbRootFile> rootFiles) {
    final maxIndex = rootFiles.fold<int>(0, (currentMax, file) {
      return max(currentMax, _indexFromFilename(file.name));
    });
    return maxIndex + 1;
  }

  int _indexFromFilename(String filename) {
    final match = _numberedAudioName.firstMatch(filename.trim());
    if (match == null) {
      return 0;
    }
    return int.tryParse(match.group(1) ?? '') ?? 0;
  }

  String _allocateFilename(
    ContentItem item, {
    required int nextIndex,
    required Set<String> usedNames,
  }) {
    var index = max(1, nextIndex);
    while (true) {
      final filename = _fileNameFor(item, index);
      if (!usedNames.contains(filename.toLowerCase())) {
        return filename;
      }
      index += 1;
    }
  }

  String _fileNameFor(ContentItem item, int index) {
    final prefix = index.toString().padLeft(3, '0');
    final kind = item.type == 'story' ? 'STORY' : 'RHYME';
    final markerPrefix = item.type == 'story' ? 'S' : 'R';
    final marker = '$markerPrefix${_contentId(item)}';
    final title = _safeTitle(item.displayTitle, maxLength: 30);
    return '${prefix}_${kind}_${title}_$marker.mp3';
  }

  String _safeTitle(String title, {required int maxLength}) {
    final normalized = title
        .toUpperCase()
        .replaceAll(RegExp(r'[^A-Z0-9]+'), '_')
        .replaceAll(RegExp(r'_+'), '_')
        .replaceAll(RegExp(r'^_|_$'), '');
    final safe = normalized.isEmpty ? 'TRACK' : normalized;
    return safe.length <= maxLength ? safe : safe.substring(0, maxLength);
  }

  String _contentKey(ContentItem item) {
    return '${item.type}:${item.language}:${_contentId(item)}';
  }

  String _entryContentKey(Map<String, dynamic> entry) {
    final explicit = entry['content_key']?.toString().trim() ?? '';
    if (explicit.isNotEmpty) {
      return explicit;
    }
    final type = entry['type']?.toString().trim() ?? '';
    final language = entry['language']?.toString().trim() ?? '';
    final id = entry['content_id']?.toString().trim() ?? '';
    if (type.isEmpty || language.isEmpty || id.isEmpty) {
      return '';
    }
    return '$type:$language:$id';
  }

  String _contentId(ContentItem item) {
    if (item.serverContentId > 0) {
      return item.serverContentId.toString();
    }
    final trimmed = item.id.trim();
    return trimmed.isEmpty ? _shortHash(item.displayTitle) : trimmed;
  }

  void _attachPlaylist(Map<String, dynamic> entry, Playlist playlist) {
    final ids = _stringList(entry['playlist_ids']).toSet();
    ids.add(playlist.id);
    entry['playlist_ids'] = ids.toList(growable: false)..sort();
    final titles = _stringList(entry['playlist_titles']).toSet();
    titles.add(playlist.title);
    entry['playlist_titles'] = titles.toList(growable: false)..sort();
  }

  List<String> _stringList(dynamic value) {
    if (value is List) {
      return value
          .map((item) => item.toString().trim())
          .where((item) => item.isNotEmpty)
          .toList(growable: false);
    }
    final text = value?.toString().trim() ?? '';
    return text.isEmpty ? const <String>[] : [text];
  }

  Future<String> _sha256(File file) async {
    return (await crypto.sha256.bind(file.openRead()).first).toString();
  }

  String _shortHash(String value) {
    return crypto.sha1.convert(utf8.encode(value)).toString().substring(0, 8);
  }

  String _localUuid() {
    final random = Random.secure();
    String four() => random.nextInt(0x10000).toRadixString(16).padLeft(4, '0');
    return '${four()}${four()}-${four()}-${four()}-${four()}-${four()}${four()}${four()}';
  }

  String _nowIso() => DateTime.now().toUtc().toIso8601String();
}

class _UsbRootFile {
  final String name;
  final int size;

  const _UsbRootFile({required this.name, required this.size});

  factory _UsbRootFile.fromJson(Map<String, dynamic> json) {
    return _UsbRootFile(
      name: (json['name'] ?? '').toString(),
      size: ((json['size'] ?? 0) as num).toInt(),
    );
  }
}

class _UsbDeviceInfo {
  final String label;
  final int capacity;
  final int freeSpace;

  const _UsbDeviceInfo({
    required this.label,
    required this.capacity,
    required this.freeSpace,
  });

  factory _UsbDeviceInfo.fromJson(Map<String, dynamic> json) {
    final label = (json['label'] ?? '').toString().trim();
    return _UsbDeviceInfo(
      label: label.isEmpty ? 'USB storage device' : label,
      capacity: ((json['capacity'] ?? 0) as num).toInt(),
      freeSpace: ((json['freeSpace'] ?? 0) as num).toInt(),
    );
  }
}

class _PreparedUsbExportItem {
  final String sourcePath;
  final int bytes;
  final String sha256;

  const _PreparedUsbExportItem({
    required this.sourcePath,
    required this.bytes,
    required this.sha256,
  });
}
