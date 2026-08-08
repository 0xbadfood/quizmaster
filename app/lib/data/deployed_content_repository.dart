import 'dart:convert';
import 'dart:io';
import 'dart:async';

import 'package:archive/archive.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

import '../models/category.dart';
import '../models/content_item.dart';
import '../models/playlist.dart';

class ContentLockedException implements Exception {
  const ContentLockedException();

  @override
  String toString() =>
      'Full library access required. Register your toy or subscribe from Parents.';
}

class DeployedContentRepository {
  DeployedContentRepository._();

  static const String _productionOrigin = 'https://api.toystech.in';
  static const String _sandboxOrigin = 'https://content.photovault.live';
  static const String _currentDirName = 'current';
  static const String _stateFileName = 'state.json';
  static const String _catalogCacheDirName = 'catalog_cache';
  static const String _catalogMetaFileName = 'meta.json';

  static final DeployedContentRepository instance =
      DeployedContentRepository._();
  final Set<String> _activePlaybackKeys = <String>{};
  final Set<String> _backgroundDownloads = <String>{};
  final Set<String> _activeDownloads = <String>{};
  String _environmentMode = 'production';
  String _sandboxLabel = '';
  String? _customerAccessToken;
  bool _customerHasFullLibrary = true;
  String _catalogIdentity = '';
  bool _catalogCacheReusable = false;

  bool get hasActiveDownloads =>
      _activeDownloads.isNotEmpty || _backgroundDownloads.isNotEmpty;
  bool get isSandboxMode =>
      _environmentMode == 'sandbox' && _sandboxLabel.isNotEmpty;
  String get sandboxLabel => _sandboxLabel;
  String get environmentMode => _environmentMode;
  String get catalogIdentity => _catalogIdentity;
  String get apiBase => isSandboxMode
      ? '$_sandboxOrigin/api/content/$_sandboxLabel'
      : '$_productionOrigin/api/content/v1';

  static List<String> _stringListFromPayload(dynamic value) {
    if (value is List) {
      return value
          .map((item) => item.toString().trim())
          .where((item) => item.isNotEmpty)
          .toList(growable: false);
    }
    final text = value?.toString().trim() ?? '';
    return text.isEmpty ? const <String>[] : [text];
  }

  Future<void> setEnvironment({
    required String mode,
    String sandboxLabel = '',
  }) async {
    final normalizedMode = mode.toLowerCase() == 'sandbox'
        ? 'sandbox'
        : 'production';
    final normalizedLabel = normalizedMode == 'sandbox'
        ? sandboxLabel.trim()
        : '';
    if (_environmentMode != normalizedMode ||
        _sandboxLabel != normalizedLabel) {
      _catalogIdentity = '';
      _catalogCacheReusable = false;
    }
    _environmentMode = normalizedMode;
    _sandboxLabel = normalizedLabel;
  }

  void setCustomerAccessToken(String? accessToken) {
    setCustomerAccess(accessToken: accessToken);
  }

  void setCustomerAccess({String? accessToken, bool hasFullLibrary = true}) {
    final trimmed = accessToken?.trim();
    _customerAccessToken = trimmed == null || trimmed.isEmpty ? null : trimmed;
    _customerHasFullLibrary = true;
  }

  Future<List<Map<String, dynamic>>> loadSandboxes() async {
    final uri = Uri.parse('$_sandboxOrigin/api/content/sandboxes');
    final response = await http.get(uri);
    if (response.statusCode == 404) {
      return const [];
    }
    if (response.statusCode != 200) {
      throw HttpException('Failed to load sandboxes: ${response.statusCode}');
    }
    final payload = jsonDecode(response.body) as Map<String, dynamic>;
    final items = (payload['sandboxes'] as List<dynamic>? ?? const <dynamic>[])
        .whereType<Map<dynamic, dynamic>>()
        .map((item) => item.cast<String, dynamic>())
        .toList(growable: false);
    return items;
  }

  Future<List<Map<String, dynamic>>> loadRemoteCategories({
    required String type,
    required String language,
  }) async {
    final cacheFile = await _catalogPayloadFile(
      'categories_${type}_$language.json',
    );
    final cachedPayload = await _readJsonFile(cacheFile);
    if (_catalogCacheReusable && cachedPayload != null) {
      return _listFromPayload(cachedPayload, 'categories');
    }

    final uri = Uri.parse('$apiBase/catalog/categories/$type/$language');
    try {
      final response = await http.get(uri, headers: _requestHeaders());
      if (response.statusCode == 404) {
        await _writeJsonFile(cacheFile, const {'categories': <dynamic>[]});
        return const [];
      }
      if (response.statusCode != 200) {
        throw HttpException(
          'Failed to load remote categories for $type/$language: ${response.statusCode}',
        );
      }
      final payload = jsonDecode(response.body) as Map<String, dynamic>;
      await _writeJsonFile(cacheFile, payload);
      return _listFromPayload(payload, 'categories');
    } catch (_) {
      if (cachedPayload != null) {
        return _listFromPayload(cachedPayload, 'categories');
      }
      rethrow;
    }
  }

  Future<Map<String, dynamic>> loadCatalogMeta() async {
    final cachedMeta = await _loadCachedCatalogMeta();
    final uri = Uri.parse('$apiBase/catalog/meta');
    try {
      final response = await http.get(uri, headers: _requestHeaders());
      if (response.statusCode != 200) {
        throw HttpException(
          'Failed to load catalog meta: ${response.statusCode}',
        );
      }
      final payload = jsonDecode(response.body) as Map<String, dynamic>;
      final remoteIdentity = _catalogIdentityFromMeta(payload);
      _catalogIdentity = remoteIdentity;
      _catalogCacheReusable = remoteIdentity.isNotEmpty;
      await _saveCatalogMeta(payload);
      return payload;
    } catch (_) {
      if (cachedMeta != null) {
        _catalogIdentity = _catalogIdentityFromMeta(cachedMeta);
        _catalogCacheReusable = _catalogIdentity.isNotEmpty;
        return cachedMeta;
      }
      rethrow;
    }
  }

  Future<List<ContentItem>> loadCategoryItems(Category category) async {
    final cacheFile = await _catalogPayloadFile(
      'category_${category.type}_${category.language}_${category.serverCategoryId}.json',
    );
    final cachedPayload = await _readJsonFile(cacheFile);
    if (_catalogCacheReusable && cachedPayload != null) {
      return _mapCategoryItemsFromPayload(category, cachedPayload);
    }

    final uri = Uri.parse(
      '$apiBase/catalog/category/${category.serverCategoryId}',
    );
    try {
      final response = await http.get(uri, headers: _requestHeaders());
      if (response.statusCode == 404) {
        await _writeJsonFile(cacheFile, const {'items': <dynamic>[]});
        return const [];
      }
      if (response.statusCode != 200) {
        throw HttpException(
          'Failed to load category ${category.serverCategoryId}: ${response.statusCode}',
        );
      }
      final payload = jsonDecode(response.body) as Map<String, dynamic>;
      await _writeJsonFile(cacheFile, payload);
      return _mapCategoryItemsFromPayload(category, payload);
    } catch (_) {
      if (cachedPayload != null) {
        return _mapCategoryItemsFromPayload(category, cachedPayload);
      }
      rethrow;
    }
  }

  Future<List<ContentItem>> loadRecentlyAddedItems() async {
    final cacheFile = await _catalogPayloadFile('recently_added.json');
    final cachedPayload = await _readJsonFile(cacheFile);
    if (_catalogCacheReusable && cachedPayload != null) {
      return _mapRecentlyAddedItemsFromPayload(cachedPayload);
    }

    final uri = Uri.parse('$apiBase/catalog/recently-added');
    try {
      final response = await http.get(uri, headers: _requestHeaders());
      if (response.statusCode == 404) {
        await _writeJsonFile(cacheFile, const {'items': <dynamic>[]});
        return const [];
      }
      if (response.statusCode != 200) {
        throw HttpException(
          'Failed to load recently added items: ${response.statusCode}',
        );
      }
      final payload = jsonDecode(response.body) as Map<String, dynamic>;
      await _writeJsonFile(cacheFile, payload);
      return _mapRecentlyAddedItemsFromPayload(payload);
    } catch (_) {
      if (cachedPayload != null) {
        return _mapRecentlyAddedItemsFromPayload(cachedPayload);
      }
      rethrow;
    }
  }

  Future<List<Playlist>> loadEditorialPlaylists() async {
    final cacheFile = await _catalogPayloadFile('playlists.json');
    final cachedPayload = await _readJsonFile(cacheFile);
    if (_catalogCacheReusable && cachedPayload != null) {
      return _mapEditorialPlaylistsFromPayload(cachedPayload);
    }

    final uri = Uri.parse('$apiBase/catalog/playlists');
    try {
      final response = await http.get(uri, headers: _requestHeaders());
      if (response.statusCode == 404) {
        await _writeJsonFile(cacheFile, const {'playlists': <dynamic>[]});
        return const [];
      }
      if (response.statusCode != 200) {
        throw HttpException(
          'Failed to load editorial playlists: ${response.statusCode}',
        );
      }
      final payload = jsonDecode(response.body) as Map<String, dynamic>;
      await _writeJsonFile(cacheFile, payload);
      return _mapEditorialPlaylistsFromPayload(payload);
    } catch (_) {
      if (cachedPayload != null) {
        return _mapEditorialPlaylistsFromPayload(cachedPayload);
      }
      rethrow;
    }
  }

  Future<String?> cachedCatalogImagePath({
    required String url,
    required String namespace,
    required String cacheKey,
  }) async {
    final trimmed = url.trim();
    if (trimmed.isEmpty) {
      return null;
    }
    final uri = Uri.tryParse(trimmed);
    if (uri == null || !(uri.scheme == 'http' || uri.scheme == 'https')) {
      return trimmed;
    }
    final file = await _catalogAssetFile(
      namespace: namespace,
      cacheKey: cacheKey,
      uri: uri,
    );
    if (await file.exists() && await file.length() > 0) {
      return file.path;
    }
    unawaited(_downloadCatalogImage(uri, file).catchError((_) {}));
    return null;
  }

  Future<List<ContentItem>> _mapCategoryItemsFromPayload(
    Category category,
    Map<String, dynamic> payload,
  ) async {
    final items = _listFromPayload(payload, 'items');
    final resolved = <ContentItem>[];
    for (final item in items) {
      resolved.add(await _mapRemoteItem(category, item));
    }
    return resolved;
  }

  Future<List<ContentItem>> _mapRecentlyAddedItemsFromPayload(
    Map<String, dynamic> payload,
  ) async {
    final items = _listFromPayload(payload, 'items');
    final resolved = <ContentItem>[];
    for (final item in items) {
      resolved.add(await _mapRecentlyAddedItem(item));
    }
    return resolved;
  }

  Future<List<Playlist>> _mapEditorialPlaylistsFromPayload(
    Map<String, dynamic> payload,
  ) async {
    final playlists = _listFromPayload(payload, 'playlists');
    final resolved = <Playlist>[];
    for (final playlist in playlists) {
      final playlistId = (playlist['id'] ?? '').toString().trim();
      final title =
          (playlist['title'] ?? playlist['name'] ?? 'StoryVault Playlist')
              .toString()
              .trim();
      final coverImageUrl =
          (playlist['cover_image_url'] ??
                  playlist['coverImageUrl'] ??
                  playlist['cover_url'] ??
                  playlist['coverUrl'] ??
                  '')
              .toString()
              .trim();
      final rawCoverImagePath = coverImageUrl.isNotEmpty
          ? coverImageUrl
          : (playlist['cover_image'] ?? playlist['coverImage'] ?? '')
                .toString()
                .trim();
      final cachedCoverImagePath = coverImageUrl.isEmpty
          ? null
          : await cachedCatalogImagePath(
              url: coverImageUrl,
              namespace: 'playlist_covers',
              cacheKey: playlistId.isEmpty
                  ? '${resolved.length + 1}'
                  : playlistId,
            );
      final coverImagePath = cachedCoverImagePath ?? rawCoverImagePath;
      final itemsPayload = _listFromPayload(playlist, 'items');
      final items = <PlaylistItem>[];
      for (final itemPayload in itemsPayload.take(kMaxItemsPerPlaylist)) {
        final position =
            ((itemPayload['playlist_position'] ?? items.length + 1) as num)
                .toInt();
        final content = await _mapRecentlyAddedItem(itemPayload);
        items.add(PlaylistItem(content: content, addedAtMillis: position));
      }
      if (items.isEmpty) {
        continue;
      }
      resolved.add(
        Playlist.create(
          id: 'editorial_${playlistId.isEmpty ? resolved.length + 1 : playlistId}',
          title: title.isEmpty ? 'StoryVault Playlist' : title,
          items: items,
          fallbackCoverImage: coverImagePath.isEmpty ? null : coverImagePath,
          readOnly: true,
        ),
      );
    }
    return resolved;
  }

  Future<ContentItem> _mapRecentlyAddedItem(
    Map<String, dynamic> payload,
  ) async {
    final contentId = ((payload['content_id'] ?? 0) as num).round();
    final categoryId = ((payload['category_id'] ?? 0) as num).round();
    final type = (payload['type'] ?? 'rhyme').toString();
    final language = (payload['language'] ?? 'english').toString();
    final itemRoot = await _itemRootDirectoryFor(
      type: type,
      language: language,
      categoryId: categoryId,
      contentId: contentId,
    );
    final currentDir = Directory('${itemRoot.path}/$_currentDirName');
    final state = await _loadItemState(itemRoot.path);
    final downloaded = await File('${currentDir.path}/bundle.json').exists();
    final remoteVersion = ((payload['bundle_version'] ?? 0) as num).round();
    final remoteSha = payload['bundle_sha256']?.toString();
    final localVersion = (state['current_version'] as num?)?.toInt() ?? 0;
    final localSha = state['current_sha256']?.toString();
    final thumbnailUrl =
        payload['thumbnail_url']?.toString() ??
        _buildThumbnailUrl(
          type: type,
          language: language,
          categoryId: categoryId,
          contentId: contentId,
        );
    final cachedThumbnail = downloaded
        ? null
        : await cachedCatalogImagePath(
            url: thumbnailUrl,
            namespace: 'thumbnails/$type/$language/$categoryId',
            cacheKey: '$contentId',
          );
    final bundleUrl =
        payload['bundle_url']?.toString() ??
        _buildBundleUrl(
          type: type,
          language: language,
          categoryId: categoryId,
          contentId: contentId,
        );
    return ContentItem(
      id: '$contentId',
      serverContentId: contentId,
      serverCategoryId: categoryId,
      type: type,
      language: language,
      title: (payload['title'] ?? '').toString(),
      category: (payload['category_name'] ?? '').toString(),
      duration: (payload['duration'] ?? '0:00').toString(),
      durationSeconds: ((payload['duration_seconds'] ?? 0) as num).round(),
      thumbnail: downloaded
          ? '${currentDir.path}/thumbnail.jpg'
          : (cachedThumbnail ?? ''),
      thumbnailUrl: thumbnailUrl,
      audioSrc: downloaded ? '${currentDir.path}/audio.mp3' : '',
      bundleFilePath: downloaded ? '${currentDir.path}/bundle.json' : null,
      bundleUrl: bundleUrl,
      bundleVersion: remoteVersion,
      bundleSha256: remoteSha,
      downloaded: downloaded,
      updateAvailable:
          downloaded &&
          _isRemoteBundleNewerFromValues(
            remoteVersion,
            remoteSha,
            localVersion,
            localSha,
          ),
      downloadInProgress: _backgroundDownloads.contains(
        '$type:$language:$categoryId:$contentId',
      ),
      isNew: true,
      isPopular: false,
      ageGroup: (payload['age_group'] ?? '').toString(),
      recommendedAgeRange: (payload['recommended_age_range'] ?? '').toString(),
      ageFilterTag: (payload['age_filter_tag'] ?? '').toString(),
      ageFilterTags: _stringListFromPayload(payload['age_filter_tags']),
      unsuitableForChildren: payload['unsuitable_for_children'] == true,
      contentWarnings: _stringListFromPayload(payload['content_warnings']),
      isHeroFree: payload['is_hero_free'] == true,
      entitlementRequired: (payload['entitlement_required'] ?? '').toString(),
      locked: payload['locked'] == true,
    );
  }

  Future<ContentItem> ensureDownloaded(ContentItem item) async {
    if ((item.bundleUrl ?? '').isEmpty) {
      return item;
    }
    if (_isLockedForCurrentCustomer(item)) {
      throw const ContentLockedException();
    }
    final itemKey = _itemKey(item);
    _activeDownloads.add(itemKey);

    try {
      final itemRoot = await _itemRootDirectory(item);
      final currentDir = await _currentDirectory(item);
      final bundleFile = File('${currentDir.path}/bundle.json');
      final state = await _loadItemState(itemRoot.path);
      final localVersion = (state['current_version'] as num?)?.toInt() ?? 0;
      final localSha = state['current_sha256']?.toString();
      final serverIsNewer = _isRemoteBundleNewer(item, localVersion, localSha);

      if (await bundleFile.exists()) {
        if (serverIsNewer) {
          _startBackgroundRefresh(item, itemRoot.path, currentDir.path);
        }
        return _hydrateDownloadedItem(
          item,
          currentDir.path,
          downloaded: true,
          updateAvailable: serverIsNewer,
          downloadInProgress: _backgroundDownloads.contains(_itemKey(item)),
        );
      }

      await _downloadAndPromoteLatest(item, itemRoot.path, currentDir.path);
      return _hydrateDownloadedItem(item, currentDir.path, downloaded: true);
    } finally {
      _activeDownloads.remove(itemKey);
    }
  }

  Future<ContentItem> _mapRemoteItem(
    Category category,
    Map<String, dynamic> payload,
  ) async {
    final contentId = ((payload['content_id'] ?? 0) as num).round();
    final itemRoot = await _itemRootDirectoryFor(
      type: category.type,
      language: category.language,
      categoryId: category.serverCategoryId,
      contentId: contentId,
    );
    final currentDir = Directory('${itemRoot.path}/$_currentDirName');
    final state = await _loadItemState(itemRoot.path);
    final downloaded = await File('${currentDir.path}/bundle.json').exists();
    final localVersion = (state['current_version'] as num?)?.toInt() ?? 0;
    final localSha = state['current_sha256']?.toString();
    final remoteVersion = ((payload['bundle_version'] ?? 0) as num).toInt();
    final remoteSha = payload['bundle_sha256']?.toString();
    final updateAvailable =
        downloaded &&
        _isRemoteBundleNewerFromValues(
          remoteVersion,
          remoteSha,
          localVersion,
          localSha,
        );
    final itemKey =
        '${category.type}:${category.language}:${category.serverCategoryId}:$contentId';
    final thumbnailUrl = _buildThumbnailUrl(
      type: category.type,
      language: category.language,
      categoryId: category.serverCategoryId,
      contentId: contentId,
    );
    final cachedThumbnail = downloaded
        ? null
        : await cachedCatalogImagePath(
            url: thumbnailUrl,
            namespace:
                'thumbnails/${category.type}/${category.language}/${category.serverCategoryId}',
            cacheKey: '$contentId',
          );

    return ContentItem(
      id: '$contentId',
      serverContentId: contentId,
      serverCategoryId: category.serverCategoryId,
      type: category.type,
      language: category.language,
      title: (payload['title'] ?? '').toString(),
      category: category.id,
      duration: (payload['duration'] ?? '0:00').toString(),
      durationSeconds: ((payload['duration_seconds'] ?? 0) as num).round(),
      thumbnail: downloaded
          ? '${currentDir.path}/thumbnail.jpg'
          : (cachedThumbnail ?? ''),
      thumbnailUrl: thumbnailUrl,
      audioSrc: downloaded ? '${currentDir.path}/audio.mp3' : '',
      bundleFilePath: downloaded ? '${currentDir.path}/bundle.json' : null,
      bundleUrl: _buildBundleUrl(
        type: category.type,
        language: category.language,
        categoryId: category.serverCategoryId,
        contentId: contentId,
      ),
      bundleVersion: remoteVersion,
      bundleSha256: remoteSha,
      downloaded: downloaded,
      updateAvailable: updateAvailable,
      downloadInProgress: _backgroundDownloads.contains(itemKey),
      isNew: true,
      isPopular: false,
      ageGroup: (payload['age_group'] ?? '').toString(),
      recommendedAgeRange: (payload['recommended_age_range'] ?? '').toString(),
      ageFilterTag: (payload['age_filter_tag'] ?? '').toString(),
      ageFilterTags: _stringListFromPayload(payload['age_filter_tags']),
      unsuitableForChildren: payload['unsuitable_for_children'] == true,
      contentWarnings: _stringListFromPayload(payload['content_warnings']),
      isHeroFree: payload['is_hero_free'] == true,
      entitlementRequired: (payload['entitlement_required'] ?? '').toString(),
      locked: payload['locked'] == true,
    );
  }

  bool _isLockedForCurrentCustomer(ContentItem item) {
    if (isSandboxMode || item.isHeroFree) {
      return false;
    }
    return item.locked && !_customerHasFullLibrary;
  }

  ContentItem _hydrateDownloadedItem(
    ContentItem item,
    String directoryPath, {
    bool? downloaded,
    bool? updateAvailable,
    bool? downloadInProgress,
  }) {
    return item.copyWith(
      thumbnail: '$directoryPath/thumbnail.jpg',
      audioSrc: '$directoryPath/audio.mp3',
      bundleFilePath: '$directoryPath/bundle.json',
      downloaded: downloaded ?? true,
      updateAvailable: updateAvailable ?? false,
      downloadInProgress: downloadInProgress ?? false,
    );
  }

  void markPlaybackStarted(ContentItem item) {
    _activePlaybackKeys.add(_itemKey(item));
  }

  Future<void> markPlaybackStopped(ContentItem item) async {
    _activePlaybackKeys.remove(_itemKey(item));
  }

  Future<void> markPlaybackCompleted(ContentItem item) async {
    _activePlaybackKeys.remove(_itemKey(item));
    await _promotePendingIfSafe(item);
  }

  String _buildThumbnailUrl({
    required String type,
    required String language,
    required int categoryId,
    required int contentId,
  }) {
    return '$apiBase/assets/thumbnail/$type/$language/$categoryId/$contentId';
  }

  String _buildBundleUrl({
    required String type,
    required String language,
    required int categoryId,
    required int contentId,
  }) {
    return '$apiBase/assets/bundle/$type/$language/$categoryId/$contentId';
  }

  Future<Directory> _contentRoot() async {
    final docsDir = await getApplicationDocumentsDirectory();
    final root = Directory('${docsDir.path}/downloaded_content');
    await root.create(recursive: true);
    return root;
  }

  Future<void> clearAllDownloadedContent() async {
    final root = await _contentRoot();
    if (await root.exists()) {
      await root.delete(recursive: true);
    }
  }

  Future<Directory> _itemRootDirectory(ContentItem item) {
    return _itemRootDirectoryFor(
      type: item.type,
      language: item.language,
      categoryId: item.serverCategoryId,
      contentId: item.serverContentId,
    );
  }

  Future<Directory> _itemRootDirectoryFor({
    required String type,
    required String language,
    required int categoryId,
    required int contentId,
  }) async {
    final root = await _contentRoot();
    return Directory('${root.path}/$type/$language/$categoryId/$contentId');
  }

  Future<Directory> _currentDirectory(ContentItem item) async {
    final root = await _itemRootDirectory(item);
    return Directory('${root.path}/$_currentDirName');
  }

  String _itemKey(ContentItem item) =>
      '${item.type}:${item.language}:${item.serverCategoryId}:${item.serverContentId}';

  bool _isRemoteBundleNewer(
    ContentItem item,
    int localVersion,
    String? localSha,
  ) {
    return _isRemoteBundleNewerFromValues(
      item.bundleVersion,
      item.bundleSha256,
      localVersion,
      localSha,
    );
  }

  bool _isRemoteBundleNewerFromValues(
    int remoteVersion,
    String? remoteSha,
    int localVersion,
    String? localSha,
  ) {
    if (remoteVersion > localVersion) {
      return true;
    }
    if (remoteVersion == localVersion &&
        remoteVersion > 0 &&
        (remoteSha ?? '').isNotEmpty &&
        remoteSha != localSha) {
      return true;
    }
    return false;
  }

  Future<Map<String, dynamic>> _loadItemState(String itemRootPath) async {
    final stateFile = File('$itemRootPath/$_stateFileName');
    if (!await stateFile.exists()) {
      return <String, dynamic>{};
    }
    try {
      final payload =
          jsonDecode(await stateFile.readAsString()) as Map<String, dynamic>;
      return payload;
    } catch (_) {
      return <String, dynamic>{};
    }
  }

  Future<void> _saveItemState(
    String itemRootPath,
    Map<String, dynamic> state,
  ) async {
    final stateFile = File('$itemRootPath/$_stateFileName');
    await stateFile.parent.create(recursive: true);
    await stateFile.writeAsString(jsonEncode(state), flush: true);
  }

  void _startBackgroundRefresh(
    ContentItem item,
    String itemRootPath,
    String currentDirPath,
  ) {
    final key = _itemKey(item);
    if (_backgroundDownloads.contains(key)) {
      return;
    }
    _backgroundDownloads.add(key);
    unawaited(
      _downloadAndStageLatest(
        item,
        itemRootPath,
        currentDirPath,
      ).catchError((_) {}).whenComplete(() {
        _backgroundDownloads.remove(key);
      }),
    );
  }

  Future<void> _downloadAndPromoteLatest(
    ContentItem item,
    String itemRootPath,
    String currentDirPath,
  ) async {
    await _downloadAndStageLatest(item, itemRootPath, currentDirPath);
    await _promotePendingIfSafe(item);
  }

  Future<void> _downloadAndStageLatest(
    ContentItem item,
    String itemRootPath,
    String currentDirPath,
  ) async {
    final version = item.bundleVersion > 0 ? item.bundleVersion : 1;
    final stagingDir = Directory('$itemRootPath/tmp_v$version');
    final bundleUri = Uri.parse(item.bundleUrl!);
    final response = await http.get(bundleUri, headers: _requestHeaders());
    if (response.statusCode != 200) {
      throw HttpException(
        'Failed to download bundle for ${item.id}: ${response.statusCode}',
      );
    }

    if (await stagingDir.exists()) {
      await stagingDir.delete(recursive: true);
    }
    await stagingDir.create(recursive: true);

    final archive = ZipDecoder().decodeBytes(response.bodyBytes);
    for (final entry in archive) {
      final outputPath = '${stagingDir.path}/${entry.name}';
      if (entry.isFile) {
        final file = File(outputPath);
        await file.parent.create(recursive: true);
        final bytes = entry.content as List<int>;
        await file.writeAsBytes(bytes, flush: true);
      } else {
        await Directory(outputPath).create(recursive: true);
      }
    }

    final bundleFile = File('${stagingDir.path}/bundle.json');
    final audioFile = File('${stagingDir.path}/audio.mp3');
    if (!await bundleFile.exists() || !await audioFile.exists()) {
      throw const FileSystemException('Downloaded bundle is incomplete');
    }

    final state = await _loadItemState(itemRootPath);
    state['pending_version'] = version;
    state['pending_sha256'] = item.bundleSha256;
    state['pending_dir'] = stagingDir.path;
    state['download_in_progress'] = false;
    await _saveItemState(itemRootPath, state);
  }

  Future<void> _promotePendingIfSafe(ContentItem item) async {
    if (_activePlaybackKeys.contains(_itemKey(item))) {
      return;
    }
    final itemRoot = await _itemRootDirectory(item);
    final itemRootPath = itemRoot.path;
    final state = await _loadItemState(itemRootPath);
    final pendingDirPath = state['pending_dir']?.toString() ?? '';
    final pendingVersion = (state['pending_version'] as num?)?.toInt() ?? 0;
    if (pendingDirPath.isEmpty || pendingVersion <= 0) {
      return;
    }
    final pendingDir = Directory(pendingDirPath);
    if (!await pendingDir.exists()) {
      state.remove('pending_dir');
      state.remove('pending_version');
      state.remove('pending_sha256');
      await _saveItemState(itemRootPath, state);
      return;
    }

    final currentDir = Directory('$itemRootPath/$_currentDirName');
    final backupDir = Directory('$itemRootPath/backup_old');
    if (await backupDir.exists()) {
      await backupDir.delete(recursive: true);
    }
    if (await currentDir.exists()) {
      await currentDir.rename(backupDir.path);
    }
    await pendingDir.rename(currentDir.path);
    if (await backupDir.exists()) {
      await backupDir.delete(recursive: true);
    }

    state['current_version'] = pendingVersion;
    state['current_sha256'] = state['pending_sha256'];
    state.remove('pending_version');
    state.remove('pending_sha256');
    state.remove('pending_dir');
    await _saveItemState(itemRootPath, state);
  }

  Future<File> _catalogPayloadFile(String fileName) async {
    final root = await _catalogIdentityDirectory();
    return File('${root.path}/${_safePathSegment(fileName)}');
  }

  Future<File> _catalogAssetFile({
    required String namespace,
    required String cacheKey,
    required Uri uri,
  }) async {
    final root = await _catalogIdentityDirectory();
    var directory = Directory('${root.path}/images');
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

  Future<Directory> _catalogEnvironmentDirectory() async {
    final docsDir = await getApplicationDocumentsDirectory();
    final directory = Directory(
      '${docsDir.path}/$_catalogCacheDirName/${_safePathSegment(_catalogEnvironmentKey())}',
    );
    await directory.create(recursive: true);
    return directory;
  }

  Future<Directory> _catalogIdentityDirectory() async {
    final environmentDirectory = await _catalogEnvironmentDirectory();
    final identity = _catalogIdentity.isEmpty
        ? 'unknown'
        : _safePathSegment(_catalogIdentity);
    final directory = Directory('${environmentDirectory.path}/$identity');
    await directory.create(recursive: true);
    return directory;
  }

  Future<File> _catalogMetaFile() async {
    final directory = await _catalogEnvironmentDirectory();
    return File('${directory.path}/$_catalogMetaFileName');
  }

  Future<Map<String, dynamic>?> _loadCachedCatalogMeta() async {
    return _readJsonFile(await _catalogMetaFile());
  }

  Future<void> _saveCatalogMeta(Map<String, dynamic> payload) async {
    await _writeJsonFile(await _catalogMetaFile(), payload);
  }

  Future<Map<String, dynamic>?> _readJsonFile(File file) async {
    if (!await file.exists()) {
      return null;
    }
    try {
      return jsonDecode(await file.readAsString()) as Map<String, dynamic>;
    } catch (_) {
      return null;
    }
  }

  Future<void> _writeJsonFile(File file, Map<String, dynamic> payload) async {
    await file.parent.create(recursive: true);
    await file.writeAsString(jsonEncode(payload), flush: true);
  }

  List<Map<String, dynamic>> _listFromPayload(
    Map<String, dynamic> payload,
    String key,
  ) {
    return (payload[key] as List<dynamic>? ?? const <dynamic>[])
        .whereType<Map<dynamic, dynamic>>()
        .map((item) => item.cast<String, dynamic>())
        .toList(growable: false);
  }

  Future<void> _downloadCatalogImage(Uri uri, File file) async {
    final response = await http.get(uri, headers: _requestHeaders());
    if (response.statusCode != 200 || response.bodyBytes.isEmpty) {
      return;
    }
    await file.parent.create(recursive: true);
    await file.writeAsBytes(response.bodyBytes, flush: true);
  }

  String _catalogEnvironmentKey() {
    final source = isSandboxMode ? 'sandbox_$_sandboxLabel' : 'production';
    final access = isSandboxMode
        ? 'sandbox'
        : (_customerHasFullLibrary ? 'full' : 'free');
    return '${source}_$access';
  }

  String _catalogIdentityFromMeta(Map<String, dynamic> payload) {
    final parts = <String>[
      if (isSandboxMode) 'sandbox=$_sandboxLabel' else 'production',
    ];
    for (final key in const [
      'goldmaster',
      'goldmaster_label',
      'active_goldmaster',
      'active_goldmaster_label',
      'catalog_epoch',
      'catalog_version',
      'catalog_updated_at',
      'category_count',
      'category_mode',
    ]) {
      final value = payload[key]?.toString().trim() ?? '';
      if (value.isNotEmpty) {
        parts.add('$key=$value');
      }
    }
    return parts.join('|');
  }

  String _safePathSegment(String value) {
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

  String _stableHash(String value) {
    var hash = 0x811c9dc5;
    for (final unit in value.codeUnits) {
      hash ^= unit;
      hash = (hash * 0x01000193) & 0xffffffff;
    }
    return hash.toRadixString(16).padLeft(8, '0');
  }

  String _imageExtension(String path) {
    final lower = path.toLowerCase();
    for (final extension in const ['.jpg', '.jpeg', '.png', '.webp']) {
      if (lower.endsWith(extension)) {
        return extension == '.jpeg' ? '.jpg' : extension;
      }
    }
    return '.jpg';
  }

  Map<String, String> _requestHeaders() {
    if (isSandboxMode || (_customerAccessToken ?? '').isEmpty) {
      return const <String, String>{};
    }
    return <String, String>{
      HttpHeaders.authorizationHeader: 'Bearer $_customerAccessToken',
    };
  }
}
