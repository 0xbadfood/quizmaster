import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

import '../models/quiz_bundle.dart';

class QuizBundleException implements Exception {
  const QuizBundleException(this.message);

  final String message;

  @override
  String toString() => message;
}

class QuizBundleRepository {
  QuizBundleRepository({
    http.Client? client,
    String apiOrigin = const String.fromEnvironment(
      'QUIZ_API_ORIGIN',
      defaultValue: 'https://quizapi.photovault.live',
    ),
    Directory? storageRoot,
  }) : _client = client ?? http.Client(),
       _apiOrigin = apiOrigin.replaceFirst(RegExp(r'/+$'), ''),
       _storageRootOverride = storageRoot;

  static final QuizBundleRepository instance = QuizBundleRepository();
  static const int rendererVersion = 1;

  final http.Client _client;
  final String _apiOrigin;
  final Directory? _storageRootOverride;
  String? _customerAccessToken;
  bool _customerHasFullLibrary = true;

  String resolveUrl(String path) => _resolve(path).toString();
  bool get customerHasFullLibrary => _customerHasFullLibrary;

  void setCustomerAccess({String? accessToken, bool hasFullLibrary = true}) {
    final trimmed = accessToken?.trim();
    _customerAccessToken = trimmed == null || trimmed.isEmpty ? null : trimmed;
    _customerHasFullLibrary = true;
  }

  Future<List<QuizCategorySummary>> loadCategories() async {
    final cache = await _catalogCacheFile();
    try {
      final response = await _client
          .get(_resolve('/api/v1/categories'), headers: _requestHeaders())
          .timeout(const Duration(seconds: 20));
      if (response.statusCode != HttpStatus.ok) {
        throw QuizBundleException(
          'Quiz catalog returned ${response.statusCode}.',
        );
      }
      final payload = _jsonObject(response.body);
      final categories = await _withCachedSelectorImages(
        _parseCategories(payload),
      );
      await _writeJsonAtomic(cache, payload);
      return categories;
    } catch (error) {
      final cached = await _readJson(cache);
      if (cached != null) {
        return _withCachedSelectorImages(_parseCategories(cached));
      }
      if (error is QuizBundleException) {
        rethrow;
      }
      throw QuizBundleException('Could not load the quiz catalog: $error');
    }
  }

  Future<DownloadedQuizCategory?> loadCached(
    QuizCategorySummary category,
  ) async {
    final versionRoot = await _versionRoot(category);
    if (!await _isReusableRelease(versionRoot, category)) {
      return null;
    }
    return _loadRelease(versionRoot, category);
  }

  Future<DownloadedQuizCategory> ensureDownloaded(
    QuizCategorySummary category, {
    ValueChanged<double>? onProgress,
  }) async {
    if (category.minimumRendererVersion > rendererVersion) {
      throw const QuizBundleException(
        'This quiz requires a newer version of StoryVault.',
      );
    }
    final versionRoot = await _versionRoot(category);
    if (await _isReusableRelease(versionRoot, category)) {
      onProgress?.call(1);
      return _loadRelease(versionRoot, category);
    }

    final categoryRoot = versionRoot.parent.parent;
    await categoryRoot.create(recursive: true);
    final archiveFile = File(
      '${categoryRoot.path}/.${category.id}-${category.bundleVersion}.zip.part',
    );
    final staging = Directory(
      '${categoryRoot.path}/.staging-${category.bundleVersion}',
    );
    if (await archiveFile.exists()) {
      await archiveFile.delete();
    }
    if (await staging.exists()) {
      await staging.delete(recursive: true);
    }

    try {
      await _download(
        _resolve(category.bundleDownloadUrl),
        archiveFile,
        expectedBytes: category.archiveBytes,
        onProgress: onProgress,
      );
      final archiveDigest = await sha256.bind(archiveFile.openRead()).first;
      if (archiveDigest.toString().toLowerCase() !=
          category.archiveSha256.toLowerCase()) {
        throw const QuizBundleException(
          'The downloaded quiz bundle failed verification.',
        );
      }

      await staging.create(recursive: true);
      await _extractArchive(archiveFile, staging);
      await _validateExtractedBundle(staging, category);

      if (await versionRoot.exists()) {
        await versionRoot.delete(recursive: true);
      }
      await versionRoot.parent.create(recursive: true);
      await staging.rename(versionRoot.path);
      await _writeJsonAtomic(File('${versionRoot.path}/release.json'), {
        'bundle_version': category.bundleVersion,
        'content_hash': category.contentHash,
        'archive_sha256': category.archiveSha256,
      });
      await _writeJsonAtomic(File('${categoryRoot.path}/current.json'), {
        'category_id': category.id,
        'bundle_version': category.bundleVersion,
        'content_hash': category.contentHash,
      });
      onProgress?.call(1);
      return _loadRelease(versionRoot, category);
    } finally {
      if (await archiveFile.exists()) {
        await archiveFile.delete();
      }
      if (await staging.exists()) {
        await staging.delete(recursive: true);
      }
    }
  }

  Future<VisualQuizDocument> loadQuiz(
    DownloadedQuizCategory category,
    QuizSetSummary quiz,
  ) async {
    final file = File(category.resolvePath(quiz.questionsFile));
    final payload = await _readJson(file);
    if (payload == null) {
      throw const QuizBundleException('Quiz questions are unavailable.');
    }
    return VisualQuizDocument.fromJson(payload);
  }

  Future<QuizProgressStyle> loadProgressStyle(
    DownloadedQuizCategory category,
  ) async {
    final path = category.definition.presentation.progressStyle;
    final payload = await _readJson(File(category.resolvePath(path)));
    if (payload == null) {
      throw const QuizBundleException('Quiz progress style is unavailable.');
    }
    return QuizProgressStyle.fromJson(payload);
  }

  Future<void> _download(
    Uri uri,
    File destination, {
    required int expectedBytes,
    ValueChanged<double>? onProgress,
  }) async {
    final request = http.Request('GET', uri);
    request.headers.addAll(_requestHeaders());
    final response = await _client
        .send(request)
        .timeout(const Duration(seconds: 30));
    if (response.statusCode != HttpStatus.ok) {
      throw QuizBundleException(
        'Quiz download returned ${response.statusCode}.',
      );
    }
    await destination.parent.create(recursive: true);
    final sink = destination.openWrite();
    var received = 0;
    final total = response.contentLength ?? expectedBytes;
    try {
      await for (final chunk in response.stream.timeout(
        const Duration(seconds: 45),
      )) {
        sink.add(chunk);
        received += chunk.length;
        if (total > 0) {
          onProgress?.call((received / total).clamp(0, 0.98));
        }
      }
    } finally {
      await sink.close();
    }
    if (expectedBytes > 0 && await destination.length() != expectedBytes) {
      throw const QuizBundleException('The quiz download is incomplete.');
    }
  }

  Future<void> _extractArchive(File source, Directory destination) async {
    final archive = ZipDecoder().decodeBytes(await source.readAsBytes());
    for (final entry in archive) {
      final relative = _safeRelativePath(entry.name);
      final output = '${destination.path}/$relative';
      if (entry.isFile) {
        final file = File(output);
        await file.parent.create(recursive: true);
        await file.writeAsBytes(entry.content as List<int>, flush: true);
      } else {
        await Directory(output).create(recursive: true);
      }
    }
  }

  Future<void> _validateExtractedBundle(
    Directory directory,
    QuizCategorySummary category,
  ) async {
    final bundle = await _readJson(File('${directory.path}/bundle.json'));
    if (bundle == null ||
        bundle['bundle_version'] != category.bundleVersion ||
        bundle['content_hash'] != category.contentHash ||
        ((bundle['minimum_renderer_version'] as num?)?.round() ??
                rendererVersion + 1) >
            rendererVersion) {
      throw const QuizBundleException('Quiz bundle metadata is invalid.');
    }
    final files = (bundle['files'] as List<dynamic>? ?? const <dynamic>[])
        .whereType<Map>()
        .map((item) => item.cast<String, dynamic>());
    for (final item in files) {
      final relative = _safeRelativePath(item['path']?.toString() ?? '');
      final file = File('${directory.path}/$relative');
      if (!await file.exists() ||
          await file.length() != (item['bytes'] as num?)?.round()) {
        throw QuizBundleException('Quiz bundle file is missing: $relative');
      }
      final digest = await sha256.bind(file.openRead()).first;
      if (digest.toString() != item['sha256']) {
        throw QuizBundleException('Quiz bundle file is damaged: $relative');
      }
    }
    final categoryPayload = await _readJson(
      File('${directory.path}/category.json'),
    );
    if (categoryPayload == null) {
      throw const QuizBundleException('Quiz category index is missing.');
    }
    final definition = QuizCategoryDefinition.fromJson(categoryPayload);
    if (definition.id != category.id ||
        definition.quizzes.length != category.quizCount) {
      throw const QuizBundleException('Quiz category index does not match.');
    }
  }

  Future<bool> _isReusableRelease(
    Directory versionRoot,
    QuizCategorySummary category,
  ) async {
    final release = await _readJson(File('${versionRoot.path}/release.json'));
    return release != null &&
        release['bundle_version'] == category.bundleVersion &&
        release['content_hash'] == category.contentHash &&
        release['archive_sha256'] == category.archiveSha256 &&
        await File('${versionRoot.path}/category.json').exists();
  }

  Future<DownloadedQuizCategory> _loadRelease(
    Directory versionRoot,
    QuizCategorySummary category,
  ) async {
    final payload = await _readJson(File('${versionRoot.path}/category.json'));
    if (payload == null) {
      throw const QuizBundleException(
        'Downloaded quiz category is unavailable.',
      );
    }
    return DownloadedQuizCategory(
      directory: versionRoot,
      definition: QuizCategoryDefinition.fromJson(payload),
      bundleVersion: category.bundleVersion,
      contentHash: category.contentHash,
    );
  }

  Future<Directory> _storageRoot() async {
    if (_storageRootOverride case final override?) {
      await override.create(recursive: true);
      return override;
    }
    final documents = await getApplicationDocumentsDirectory();
    final root = Directory('${documents.path}/quiz_categories');
    await root.create(recursive: true);
    return root;
  }

  Future<void> clearAllDownloadedContent() async {
    final root = await _storageRoot();
    if (await root.exists()) {
      await root.delete(recursive: true);
    }
  }

  Future<Directory> _versionRoot(QuizCategorySummary category) async {
    final root = await _storageRoot();
    final version = category.bundleVersion.toString().padLeft(6, '0');
    return Directory('${root.path}/${category.id}/versions/$version');
  }

  Future<File> _catalogCacheFile() async {
    final root = await _storageRoot();
    return File('${root.path}/catalog.json');
  }

  Future<List<QuizCategorySummary>> _withCachedSelectorImages(
    List<QuizCategorySummary> categories,
  ) async {
    if (categories.isEmpty) {
      return categories;
    }
    return Future.wait(
      categories.map((category) async {
        final cachedPath = await _cachedSelectorImagePath(category);
        return cachedPath == null
            ? category
            : category.copyWith(cachedSelectorImagePath: cachedPath);
      }),
    );
  }

  Future<String?> _cachedSelectorImagePath(QuizCategorySummary category) async {
    final selector = category.selectorUrl.trim();
    if (selector.isEmpty) {
      return null;
    }
    final uri = _resolve(selector);
    if (!(uri.scheme == 'http' || uri.scheme == 'https')) {
      return selector;
    }
    final file = await _catalogAssetFile(
      namespace: 'selector_icons',
      cacheKey: '${category.id}_${category.contentHash}',
      uri: uri,
    );
    if (await file.exists() && await file.length() > 0) {
      return file.path;
    }
    unawaited(_downloadCatalogImage(uri, file).catchError((_) {}));
    return null;
  }

  Future<File> _catalogAssetFile({
    required String namespace,
    required String cacheKey,
    required Uri uri,
  }) async {
    final root = await _storageRoot();
    var directory = Directory('${root.path}/catalog_images');
    for (final rawSegment in namespace.split('/')) {
      final segment = _safePathSegment(rawSegment);
      if (segment.isNotEmpty) {
        directory = Directory('${directory.path}/$segment');
      }
    }
    await directory.create(recursive: true);
    return File(
      '${directory.path}/${_safePathSegment(cacheKey)}${_imageExtension(uri.path)}',
    );
  }

  Future<void> _downloadCatalogImage(Uri uri, File file) async {
    final response = await _client
        .get(uri)
        .timeout(const Duration(seconds: 20));
    if (response.statusCode != HttpStatus.ok || response.bodyBytes.isEmpty) {
      return;
    }
    await file.parent.create(recursive: true);
    await file.writeAsBytes(response.bodyBytes, flush: true);
  }

  Uri _resolve(String path) {
    final base = Uri.parse('$_apiOrigin/');
    return base.resolve(path.startsWith('/') ? path.substring(1) : path);
  }

  Map<String, String> _requestHeaders() {
    final token = _customerAccessToken;
    if (token == null || token.isEmpty) {
      return const {};
    }
    return {'Authorization': 'Bearer $token'};
  }

  static List<QuizCategorySummary> _parseCategories(
    Map<String, dynamic> payload,
  ) {
    return (payload['categories'] as List<dynamic>? ?? const <dynamic>[])
        .whereType<Map>()
        .map(
          (item) => QuizCategorySummary.fromJson(item.cast<String, dynamic>()),
        )
        .toList(growable: false);
  }

  static Map<String, dynamic> _jsonObject(String source) {
    final value = jsonDecode(source);
    if (value is! Map) {
      throw const FormatException('Expected a JSON object.');
    }
    return value.cast<String, dynamic>();
  }

  static Future<Map<String, dynamic>?> _readJson(File file) async {
    if (!await file.exists()) {
      return null;
    }
    try {
      return _jsonObject(await file.readAsString());
    } catch (_) {
      return null;
    }
  }

  static Future<void> _writeJsonAtomic(
    File destination,
    Map<String, dynamic> payload,
  ) async {
    await destination.parent.create(recursive: true);
    final temporary = File('${destination.path}.tmp');
    await temporary.writeAsString(jsonEncode(payload), flush: true);
    await temporary.rename(destination.path);
  }

  static String _safeRelativePath(String value) {
    final normalized = value.replaceAll('\\', '/').trim();
    final segments = normalized.split('/');
    if (normalized.isEmpty ||
        normalized.startsWith('/') ||
        segments.any((segment) => segment.isEmpty || segment == '..')) {
      throw const QuizBundleException('Quiz bundle contains an unsafe path.');
    }
    return normalized;
  }

  static String _safePathSegment(String value) {
    final normalized = value
        .trim()
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9._-]+'), '_')
        .replaceAll(RegExp(r'_+'), '_')
        .replaceAll(RegExp(r'^_|_$'), '');
    final safe = normalized.isEmpty ? 'item' : normalized;
    if (safe.length <= 96) {
      return safe;
    }
    return '${safe.substring(0, 64)}_${_stableHash(value)}';
  }

  static String _stableHash(String value) {
    var hash = 0x811c9dc5;
    for (final unit in value.codeUnits) {
      hash ^= unit;
      hash = (hash * 0x01000193) & 0xffffffff;
    }
    return hash.toRadixString(16).padLeft(8, '0');
  }

  static String _imageExtension(String path) {
    final lower = path.toLowerCase();
    for (final extension in const ['.jpg', '.jpeg', '.png', '.webp']) {
      if (lower.endsWith(extension)) {
        return extension == '.jpeg' ? '.jpg' : extension;
      }
    }
    return '.jpg';
  }
}

typedef ValueChanged<T> = void Function(T value);
