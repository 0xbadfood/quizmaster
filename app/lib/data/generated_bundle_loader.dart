import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show FlutterError;
import 'package:flutter/services.dart' show rootBundle;

import '../models/content_item.dart';
import '../models/player_bundle.dart';

class GeneratedBundleLoader {
  const GeneratedBundleLoader._();

  static Future<PlayerBundle?> load(String? assetPath) async {
    final normalized = (assetPath ?? '').trim();
    if (normalized.isEmpty) {
      return null;
    }

    try {
      final payload = await _loadBundlePayload(normalized);
      if (payload is! Map<String, dynamic>) {
        throw const FormatException('Generated player bundle must be a JSON object.');
      }
      return PlayerBundle.fromJson(payload);
    } on FlutterError {
      return null;
    }
  }

  static Future<dynamic> _loadBundlePayload(String path) async {
    final file = _fileForPath(path);
    if (_looksLikeFilePath(path) && await file.exists()) {
      final jsonText = await file.readAsString();
      final payload = json.decode(jsonText);
      if (payload is! Map<String, dynamic>) {
        throw const FormatException('Generated player bundle must be a JSON object.');
      }
      return _normalizeLocalBundlePayload(payload, file.parent.path, file.path);
    }
    final jsonText = await rootBundle.loadString(path);
    return json.decode(jsonText);
  }

  static Map<String, dynamic> _normalizeLocalBundlePayload(
    Map<String, dynamic> payload,
    String bundleDirectoryPath,
    String bundleFilePath,
  ) {
    String resolveLocalPath(String value) {
      final normalized = value.trim();
      if (normalized.isEmpty || normalized.startsWith('/') || normalized.startsWith('http')) {
        return normalized;
      }
      return '$bundleDirectoryPath/$normalized';
    }

    final normalizedPayload = Map<String, dynamic>.from(payload);
    final content = Map<String, dynamic>.from((payload['content'] as Map?)?.cast<String, dynamic>() ?? const {});
    if (content.isNotEmpty) {
      final contentId = ((content['content_id'] ?? 0) as num?)?.round() ?? 0;
      if (contentId > 0) {
        content['id'] = '$contentId';
        content['content_id'] = contentId;
      }
      content['thumbnail'] = resolveLocalPath((content['thumbnail'] ?? '').toString());
      content['audio_src'] = resolveLocalPath((content['audio_src'] ?? '').toString());
      content['bundle_file_path'] = bundleFilePath;
      content['downloaded'] = true;
      normalizedPayload['content'] = content;
    }

    final scenes = (payload['scenes'] as List<dynamic>? ?? const [])
        .whereType<Map>()
        .map((scene) {
          final copy = Map<String, dynamic>.from(scene.cast<String, dynamic>());
          copy['image'] = resolveLocalPath((copy['image'] ?? '').toString());
          return copy;
        })
        .toList(growable: false);
    normalizedPayload['scenes'] = scenes;
    return normalizedPayload;
  }

  static bool _looksLikeFilePath(String path) {
    return path.startsWith('/') || path.startsWith('file://');
  }

  static File _fileForPath(String path) {
    return path.startsWith('file://') ? File.fromUri(Uri.parse(path)) : File(path);
  }

  static Future<List<ContentItem>> loadContentIndex(String assetPath) async {
    try {
      final jsonText = await rootBundle.loadString(assetPath);
      final payload = json.decode(jsonText);
      if (payload is! Map<String, dynamic>) {
        return const [];
      }
      final items = (payload['items'] as List<dynamic>? ?? const []);
      return items
          .whereType<Map<dynamic, dynamic>>()
          .map((item) => ContentItem.fromJson(item.cast<String, dynamic>()))
          .toList();
    } on FlutterError {
      return const [];
    }
  }
}
