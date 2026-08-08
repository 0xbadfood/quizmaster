import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:math';
import '../models/content_item.dart';
import '../models/playlist.dart';
import '../models/category.dart';
import '../models/quiz.dart';
import '../data/category_registry.dart';
import '../data/deployed_content_repository.dart';
import '../data/quiz_bundle_repository.dart';
import '../customer/customer_api_client.dart';
import '../customer/customer_auth_service.dart';
import '../customer/customer_session.dart';

/// Central app state using ChangeNotifier (Provider pattern)
class AppState extends ChangeNotifier {
  static const String _lastPlayedItemKey = 'last_played_item_json';
  static const String _lastPlayedPositionKey = 'last_played_position_seconds';
  static const String _lastPlayedDurationKey = 'last_played_duration_seconds';
  static const String _lastPlayedPlaylistContextKey =
      'last_played_playlist_context_json';
  static const String _playlistsKey = 'playlists_json_v2';
  static const String _playlistOnlyForKidsKey = 'playlist_only_for_kids';
  static const String _quizEnabledKey = 'story_quiz_enabled';
  static const String _waitForQuizExplanationAudioKey =
      'visual_quiz_wait_for_explanation_audio';
  static const String _quizAttemptsKey = 'story_quiz_attempts_json_v1';
  static const String _contentEnvironmentModeKey = 'content_environment_mode';
  static const String _sandboxLabelKey = 'content_environment_sandbox_label';
  static const String _catalogEpochKey = 'content_catalog_epoch';
  static const String _catalogIdentityKey = 'content_catalog_identity';
  static const String _productionCategoryModeKey = 'production_category_mode';
  final CustomerApiClient _customerApiClient = CustomerApiClient();
  final CustomerAuthService _customerAuthService = CustomerAuthService();

  // ===== Parent Mode =====
  bool _parentMode = false;
  bool get parentMode => _parentMode;

  bool _playlistOnlyForKids = false;
  bool get playlistOnlyForKids => _playlistOnlyForKids;
  bool _quizEnabled = true;
  bool get quizEnabled => _quizEnabled;
  bool _waitForQuizExplanationAudio = true;
  bool get waitForQuizExplanationAudio => _waitForQuizExplanationAudio;
  Map<String, QuizAttemptResult> _quizAttempts = const {};
  Map<String, QuizAttemptResult> get quizAttempts =>
      Map<String, QuizAttemptResult>.unmodifiable(_quizAttempts);

  void unlockParentMode() {
    _parentMode = true;
    notifyListeners();
  }

  void lockParentMode() {
    _parentMode = false;
    notifyListeners();
  }

  Future<void> setPlaylistOnlyForKids(bool enabled) async {
    if (_playlistOnlyForKids == enabled) {
      return;
    }
    _playlistOnlyForKids = enabled;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_playlistOnlyForKidsKey, enabled);
  }

  Future<void> setQuizEnabled(bool enabled) async {
    if (_quizEnabled == enabled) {
      return;
    }
    _quizEnabled = enabled;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_quizEnabledKey, enabled);
  }

  Future<void> setWaitForQuizExplanationAudio(bool enabled) async {
    if (_waitForQuizExplanationAudio == enabled) {
      return;
    }
    _waitForQuizExplanationAudio = enabled;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_waitForQuizExplanationAudioKey, enabled);
  }

  bool hasQuizAttempt(ContentItem item) {
    return _quizAttempts.containsKey(QuizAttemptResult.storyKeyFor(item));
  }

  QuizAttemptResult? quizAttemptFor(ContentItem item) {
    return _quizAttempts[QuizAttemptResult.storyKeyFor(item)];
  }

  Future<QuizAttemptResult> recordQuizAttempt({
    required ContentItem item,
    required StoryQuiz quiz,
    required Map<String, int> selectedIndexes,
  }) async {
    final storyKey = QuizAttemptResult.storyKeyFor(item);
    final existing = _quizAttempts[storyKey];
    if (existing != null) {
      return existing;
    }

    var correctCount = 0;
    final correctIndexes = <String, int>{};
    for (final question in quiz.questions) {
      correctIndexes[question.key] = question.correctIndex;
      if (selectedIndexes[question.key] == question.correctIndex) {
        correctCount += 1;
      }
    }
    final result = QuizAttemptResult(
      storyKey: storyKey,
      storyId: item.serverContentId > 0
          ? item.serverContentId
          : int.tryParse(item.id) ?? 0,
      storyTitle: item.displayTitle,
      questionCount: quiz.questions.length,
      correctCount: correctCount,
      selectedIndexes: Map<String, int>.from(selectedIndexes),
      correctIndexes: correctIndexes,
      completedAtMillis: DateTime.now().millisecondsSinceEpoch,
    );
    _quizAttempts = {..._quizAttempts, storyKey: result};
    notifyListeners();
    await _persistQuizAttempts();
    return result;
  }

  // ===== Navigation =====
  int _selectedNavIndex = 0;
  int get selectedNavIndex => _selectedNavIndex;

  void setNavIndex(int index) {
    _selectedNavIndex = index;
    notifyListeners();
  }

  // ===== Current Playing Item =====
  ContentItem? _currentPlayingItem;
  ContentItem? get currentPlayingItem => _currentPlayingItem;

  void setCurrentPlayingItem(ContentItem? item) {
    _currentPlayingItem = item;
    notifyListeners();
  }

  // ===== Last Played / Resume =====
  ContentItem? _lastPlayedItem;
  ContentItem? get lastPlayedItem => _lastPlayedItem;
  PlaylistPlaybackContext? _lastPlayedPlaylistContext;
  PlaylistPlaybackContext? get lastPlayedPlaylistContext =>
      _lastPlayedPlaylistContext;

  double _lastPlayedPositionSeconds = 0.0;
  double get lastPlayedPositionSeconds => _lastPlayedPositionSeconds;

  double _lastPlayedDurationSeconds = 0.0;
  double get lastPlayedDurationSeconds => _lastPlayedDurationSeconds;

  double get lastPlayedProgress {
    final total = _lastPlayedDurationSeconds > 0
        ? _lastPlayedDurationSeconds
        : (_lastPlayedItem?.durationSeconds.toDouble() ?? 0.0);
    if (total <= 0) {
      return 0.0;
    }
    return (_lastPlayedPositionSeconds / total).clamp(0.0, 1.0);
  }

  // ===== Playlists =====
  late List<Playlist> _playlists;
  List<Playlist> _editorialPlaylists = const [];
  Playlist? _activePlaybackQueue;
  List<ContentItem> _recentlyAddedItems = const [];
  List<ContentItem> get recentlyAddedItems =>
      List<ContentItem>.unmodifiable(_recentlyAddedItems);
  bool _recentlyAddedLoading = true;
  bool get recentlyAddedLoading => _recentlyAddedLoading;
  String _contentEnvironmentMode = 'production';
  String get contentEnvironmentMode => _contentEnvironmentMode;
  String _sandboxLabel = '';
  String get sandboxLabel => _sandboxLabel;
  bool _contentEnvironmentLoading = true;
  bool get contentEnvironmentLoading => _contentEnvironmentLoading;
  bool get sandboxMode =>
      _contentEnvironmentMode == 'sandbox' && _sandboxLabel.isNotEmpty;
  int _catalogEpoch = 0;
  int get catalogEpoch => _catalogEpoch;
  String _catalogIdentity = '';
  String _productionCategoryMode = 'static';
  String get productionCategoryMode => _productionCategoryMode;
  bool get productionUsesDynamicCategories =>
      _productionCategoryMode == 'dynamic';
  List<Map<String, dynamic>> _availableSandboxes = const [];
  List<Map<String, dynamic>> get availableSandboxes =>
      List<Map<String, dynamic>>.unmodifiable(_availableSandboxes);
  bool _sandboxDirectoryLoading = false;
  bool get sandboxDirectoryLoading => _sandboxDirectoryLoading;
  String? _sandboxDirectoryError;
  String? get sandboxDirectoryError => _sandboxDirectoryError;
  final Map<String, List<Category>> _remoteStoryCategories = {
    'english': const [],
    'hindi': const [],
  };
  final Map<String, List<Category>> _remoteRhymeCategories = {
    'english': const [],
  };
  CustomerSession? _customerSession;
  CustomerSession? get customerSession => _customerSession;
  CustomerProfile? _customerProfile;
  CustomerProfile? get customerProfile => _customerProfile;
  final bool _customerSessionLoading = false;
  bool get customerSessionLoading => _customerSessionLoading;
  String? _customerSessionError;
  String? get customerSessionError => _customerSessionError;
  bool get hasCustomerSession => _customerSession?.isUsable == true;
  bool get customerEntitled => true;
  bool get customerOnboardingComplete =>
      _customerProfile?.onboardingComplete == true;

  void _syncCustomerAccessToRepository() {
    DeployedContentRepository.instance.setCustomerAccess(
      accessToken: _customerSession?.accessToken,
      hasFullLibrary: true,
    );
    QuizBundleRepository.instance.setCustomerAccess(
      accessToken: _customerSession?.accessToken,
      hasFullLibrary: true,
    );
  }

  AppState() {
    _playlists = const [];
    _loadPlaylists();
    _loadLastPlayed();
    _syncCustomerAccessToRepository();
    unawaited(_loadContentEnvironment());
  }

  List<Category> storyCategoriesFor(String _) {
    if (sandboxMode || productionUsesDynamicCategories) {
      return List<Category>.unmodifiable(
        _remoteStoryCategories['english'] ?? const [],
      );
    }
    return CategoryRegistry.instance.storyCategoriesFor('english');
  }

  List<Category> rhymeCategoriesFor(String _) {
    if (sandboxMode || productionUsesDynamicCategories) {
      return List<Category>.unmodifiable(
        _remoteRhymeCategories['english'] ?? const [],
      );
    }
    return CategoryRegistry.instance.rhymeCategoriesFor('english');
  }

  Future<void> refreshSandboxDirectory() async {
    _sandboxDirectoryLoading = true;
    _sandboxDirectoryError = null;
    notifyListeners();
    try {
      final items = await DeployedContentRepository.instance.loadSandboxes();
      _availableSandboxes = items;
    } catch (error) {
      _availableSandboxes = const [];
      _sandboxDirectoryError = error.toString();
    } finally {
      _sandboxDirectoryLoading = false;
      notifyListeners();
    }
  }

  Future<String> _resolveSandboxLabel(String requestedLabel) async {
    final requested = requestedLabel.trim();
    var items = _availableSandboxes;
    if (items.isEmpty) {
      try {
        items = await DeployedContentRepository.instance.loadSandboxes();
        _availableSandboxes = items;
        _sandboxDirectoryError = null;
      } catch (error) {
        _availableSandboxes = const [];
        _sandboxDirectoryError = error.toString();
        return requested == 'current' ? '' : requested;
      }
    }

    final labels = items
        .map((item) => (item['label'] ?? '').toString().trim())
        .where((label) => label.isNotEmpty)
        .toList(growable: false);
    if (labels.isEmpty) {
      return requested == 'current' ? '' : requested;
    }
    if (requested.isEmpty ||
        requested == 'current' ||
        !labels.contains(requested)) {
      return labels.first;
    }
    return requested;
  }

  Future<void> setContentEnvironment({
    required String mode,
    String sandboxLabel = '',
  }) async {
    final normalizedMode = mode.toLowerCase() == 'sandbox'
        ? 'sandbox'
        : 'production';
    final normalizedLabel = normalizedMode == 'sandbox'
        ? await _resolveSandboxLabel(sandboxLabel)
        : '';
    if (_contentEnvironmentMode == normalizedMode &&
        _sandboxLabel == normalizedLabel) {
      return;
    }

    await DeployedContentRepository.instance.clearAllDownloadedContent();
    await DeployedContentRepository.instance.setEnvironment(
      mode: normalizedMode,
      sandboxLabel: normalizedLabel,
    );

    _contentEnvironmentMode = normalizedMode;
    _sandboxLabel = normalizedLabel;
    _recentlyAddedItems = const [];
    _recentlyAddedLoading = true;
    _playlists = const [];
    _editorialPlaylists = const [];
    _activePlaybackQueue = null;
    _lastPlayedItem = null;
    _lastPlayedPlaylistContext = null;
    _lastPlayedPositionSeconds = 0.0;
    _lastPlayedDurationSeconds = 0.0;
    _currentPlayingItem = null;

    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_lastPlayedItemKey);
    await prefs.remove(_lastPlayedPositionKey);
    await prefs.remove(_lastPlayedDurationKey);
    await prefs.remove(_lastPlayedPlaylistContextKey);
    await prefs.remove(_playlistsKey);
    await prefs.setString(_contentEnvironmentModeKey, normalizedMode);
    if (normalizedMode == 'sandbox') {
      await prefs.setString(_sandboxLabelKey, normalizedLabel);
    } else {
      await prefs.remove(_sandboxLabelKey);
    }

    await _refreshCatalogModeAndCategories(
      prefs: prefs,
      resetAlreadyApplied: true,
    );

    notifyListeners();
    _scheduleRecentlyAddedRefresh(delay: Duration.zero, retries: 4);
    unawaited(_refreshEditorialPlaylists(retries: 4));
  }

  Future<void> saveCustomerSession(
    CustomerSession session, {
    String clearLocalDataIfUserChangesFrom = '',
  }) async {
    _customerSession = session;
    _customerProfile = null;
    _customerSessionError = null;
    _syncCustomerAccessToRepository();
    await _customerApiClient.saveSession(session);
    await refreshCustomerProfile();
    final previousUserId = clearLocalDataIfUserChangesFrom.trim();
    final currentUserId = _customerProfile?.userId.trim() ?? '';
    if (previousUserId.isNotEmpty &&
        currentUserId.isNotEmpty &&
        previousUserId != currentUserId) {
      await _clearLocalPersonalizedData();
      notifyListeners();
    }
  }

  Future<void> signInWithGoogle() async {
    final session = await _customerAuthService.signInWithGoogle(
      _customerApiClient,
    );
    await saveCustomerSession(session);
  }

  Future<void> reauthenticateWithGoogleForPinReset() async {
    final previousUserId = _customerProfile?.userId.trim() ?? '';
    final session = await _customerAuthService.signInWithGoogle(
      _customerApiClient,
    );
    await saveCustomerSession(
      session,
      clearLocalDataIfUserChangesFrom: previousUserId,
    );
  }

  Future<void> signInWithApple() async {
    final session = await _customerAuthService.signInWithApple(
      _customerApiClient,
    );
    await saveCustomerSession(session);
  }

  Future<void> reauthenticateWithAppleForPinReset() async {
    final previousUserId = _customerProfile?.userId.trim() ?? '';
    final session = await _customerAuthService.signInWithApple(
      _customerApiClient,
    );
    await saveCustomerSession(
      session,
      clearLocalDataIfUserChangesFrom: previousUserId,
    );
  }

  Future<void> refreshCustomerProfile() async {
    final session = await _validCustomerSession();
    if (session == null) {
      _customerProfile = null;
      _syncCustomerAccessToRepository();
      notifyListeners();
      return;
    }
    try {
      _customerProfile = await _customerApiClient.me(session);
      _customerSessionError = null;
      await _customerApiClient.saveProfile(_customerProfile!);
      _syncCustomerAccessToRepository();
    } catch (error) {
      _customerSessionError = error.toString();
      if (_isLikelyOfflineError(error)) {
        _customerProfile ??= await _customerApiClient.loadStoredProfile();
        _syncCustomerAccessToRepository();
      }
    }
    notifyListeners();
  }

  Future<void> updateParentProfile(String displayName) async {
    final session = await _validCustomerSession();
    if (session == null) {
      throw StateError('Sign in before setting up the parent profile.');
    }
    _customerProfile = await _customerApiClient.updateParent(
      session: session,
      displayName: displayName.trim(),
    );
    _customerSessionError = null;
    await _customerApiClient.saveProfile(_customerProfile!);
    _syncCustomerAccessToRepository();
    notifyListeners();
  }

  Future<void> createChildProfile({
    required String nickname,
    required String ageGroup,
  }) async {
    final session = await _validCustomerSession();
    if (session == null) {
      throw StateError('Sign in before creating a child profile.');
    }
    _customerProfile = await _customerApiClient.createChild(
      session: session,
      nickname: nickname.trim(),
      ageGroup: ageGroup,
    );
    _customerSessionError = null;
    await _customerApiClient.saveProfile(_customerProfile!);
    _syncCustomerAccessToRepository();
    notifyListeners();
  }

  Future<void> setParentPin(String pin) async {
    final normalizedPin = pin.trim();
    if (normalizedPin.length != 4 || int.tryParse(normalizedPin) == null) {
      throw StateError('PIN must be exactly 4 digits.');
    }
    final session = await _validCustomerSession();
    if (session == null) {
      throw StateError('Sign in before setting a parent PIN.');
    }
    _customerProfile = await _customerApiClient.setPin(
      session: session,
      pin: normalizedPin,
    );
    _customerSessionError = null;
    await _customerApiClient.saveProfile(_customerProfile!);
    _syncCustomerAccessToRepository();
    notifyListeners();
  }

  Future<void> verifyParentPin(String pin) async {
    final normalizedPin = pin.trim();
    if (sandboxMode && _customerSession == null) {
      if (normalizedPin == '1234') {
        unlockParentMode();
        return;
      }
      throw StateError('Incorrect PIN. Try again.');
    }
    final session = await _validCustomerSession();
    if (session == null) {
      throw StateError('Sign in before unlocking Parent Mode.');
    }
    await _customerApiClient.verifyPin(session: session, pin: normalizedPin);
    unlockParentMode();
  }

  Future<void> signOutCustomer() async {
    final session = _customerSession;
    _customerSession = null;
    _customerProfile = null;
    _customerSessionError = null;
    _parentMode = false;
    await _clearLocalPersonalizedData();
    _syncCustomerAccessToRepository();
    notifyListeners();
    await _customerApiClient.logout(session);
  }

  Future<void> _clearLocalPersonalizedData() async {
    await DeployedContentRepository.instance.clearAllDownloadedContent();
    await QuizBundleRepository.instance.clearAllDownloadedContent();
    _playlists = const [];
    _editorialPlaylists = const [];
    _activePlaybackQueue = null;
    _playlistOnlyForKids = false;
    _quizEnabled = true;
    _waitForQuizExplanationAudio = true;
    _quizAttempts = const {};
    _lastPlayedItem = null;
    _lastPlayedPlaylistContext = null;
    _lastPlayedPositionSeconds = 0.0;
    _lastPlayedDurationSeconds = 0.0;
    _currentPlayingItem = null;

    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_playlistsKey);
    await prefs.remove(_playlistOnlyForKidsKey);
    await prefs.remove(_quizEnabledKey);
    await prefs.remove(_waitForQuizExplanationAudioKey);
    await prefs.remove(_quizAttemptsKey);
    await prefs.remove(_lastPlayedItemKey);
    await prefs.remove(_lastPlayedPositionKey);
    await prefs.remove(_lastPlayedDurationKey);
    await prefs.remove(_lastPlayedPlaylistContextKey);
  }

  Future<void> redeemToyCode(String code) async {
    final session = await _validCustomerSession();
    if (session == null) {
      throw StateError('Sign in before redeeming a toy code.');
    }
    _customerProfile = await _customerApiClient.redeemToyCode(
      session: session,
      code: code,
    );
    _customerSessionError = null;
    await _customerApiClient.saveProfile(_customerProfile!);
    _syncCustomerAccessToRepository();
    notifyListeners();
  }

  List<Playlist> get playlists =>
      List<Playlist>.unmodifiable([..._editorialPlaylists, ..._playlists]);
  List<Playlist> get editablePlaylists =>
      List<Playlist>.unmodifiable(_playlists);
  bool get canCreatePlaylist => _playlists.length < kMaxPlaylists;
  int get remainingPlaylistSlots => max(0, kMaxPlaylists - _playlists.length);

  Playlist? getPlaylistById(String id) {
    final activeQueue = _activePlaybackQueue;
    if (activeQueue != null && activeQueue.id == id) {
      return activeQueue;
    }
    try {
      return playlists.firstWhere((p) => p.id == id);
    } catch (_) {
      return null;
    }
  }

  PlaylistPlaybackContext createPlaybackQueue({
    required String title,
    required List<ContentItem> items,
    required int startIndex,
  }) {
    final safeItems = items
        .where((item) => item.id.trim().isNotEmpty)
        .map(PlaylistItem.fromContent)
        .toList(growable: false);
    if (safeItems.isEmpty) {
      throw ArgumentError.value(items, 'items', 'Playback queue is empty.');
    }
    final clampedIndex = startIndex.clamp(0, safeItems.length - 1).toInt();
    final now = DateTime.now().millisecondsSinceEpoch;
    _activePlaybackQueue = Playlist(
      id: 'category_queue_$now',
      title: title.trim().isEmpty ? 'Now Playing' : title.trim(),
      items: safeItems,
      maxItems: safeItems.length,
      createdAtMillis: now,
      updatedAtMillis: now,
      readOnly: true,
    );
    return PlaylistPlaybackContext(
      playlistId: _activePlaybackQueue!.id,
      itemIndex: clampedIndex,
    );
  }

  bool isTransientPlaybackContext(PlaylistPlaybackContext? context) {
    final activeQueue = _activePlaybackQueue;
    return context != null &&
        activeQueue != null &&
        context.playlistId == activeQueue.id;
  }

  List<Playlist> playlistsContainingItem(ContentItem item) {
    return playlists
        .where((playlist) => playlist.containsContent(item))
        .toList(growable: false);
  }

  List<Playlist> editablePlaylistsContainingItem(ContentItem item) {
    return _playlists
        .where((playlist) => playlist.containsContent(item))
        .toList(growable: false);
  }

  bool isInPlaylist(String playlistId, ContentItem item) {
    final playlist = getPlaylistById(playlistId);
    return playlist?.containsContent(item) ?? false;
  }

  PlaylistItem? playlistItemAt(String playlistId, int itemIndex) {
    final playlist = getPlaylistById(playlistId);
    if (playlist == null ||
        itemIndex < 0 ||
        itemIndex >= playlist.items.length) {
      return null;
    }
    return playlist.items[itemIndex];
  }

  PlaylistPlaybackContext? nextPlaylistContext(
    PlaylistPlaybackContext context,
  ) {
    final playlist = getPlaylistById(context.playlistId);
    if (playlist == null) {
      return null;
    }
    final nextIndex = context.itemIndex + 1;
    if (nextIndex >= playlist.items.length) {
      return null;
    }
    return context.copyWith(itemIndex: nextIndex);
  }

  PlaylistPlaybackContext? previousPlaylistContext(
    PlaylistPlaybackContext context,
  ) {
    final playlist = getPlaylistById(context.playlistId);
    if (playlist == null) {
      return null;
    }
    final previousIndex = context.itemIndex - 1;
    if (previousIndex < 0 || previousIndex >= playlist.items.length) {
      return null;
    }
    return context.copyWith(itemIndex: previousIndex);
  }

  bool canAddToPlaylist(String playlistId, ContentItem item) {
    final playlist = getPlaylistById(playlistId);
    if (playlist == null) {
      return false;
    }
    if (playlist.readOnly) {
      return false;
    }
    if (playlist.containsContent(item)) {
      return false;
    }
    return playlist.itemCount < playlist.maxItems;
  }

  Playlist? createPlaylist(String title, {ContentItem? initialItem}) {
    if (!canCreatePlaylist) {
      return null;
    }
    final trimmed = title.trim();
    final safeTitle = trimmed.isEmpty
        ? 'Playlist ${_playlists.length + 1}'
        : trimmed;
    final playlist = Playlist.create(
      id: 'playlist_${DateTime.now().millisecondsSinceEpoch}',
      title: safeTitle,
      items: initialItem == null
          ? const []
          : [PlaylistItem.fromContent(initialItem)],
    );
    _playlists = [..._playlists, playlist];
    notifyListeners();
    _persistPlaylists();
    return playlist;
  }

  bool deletePlaylist(String playlistId) {
    if (getPlaylistById(playlistId)?.readOnly == true) {
      return false;
    }
    final before = _playlists.length;
    _playlists = _playlists
        .where((playlist) => playlist.id != playlistId)
        .toList(growable: false);
    final changed = _playlists.length != before;
    if (changed) {
      notifyListeners();
      _persistPlaylists();
    }
    return changed;
  }

  bool addToPlaylist(String playlistId, ContentItem item) {
    if (getPlaylistById(playlistId)?.readOnly == true) {
      return false;
    }
    final index = _playlists.indexWhere(
      (playlist) => playlist.id == playlistId,
    );
    if (index < 0) {
      return false;
    }
    final playlist = _playlists[index];
    if (playlist.containsContent(item) || playlist.isFull) {
      return false;
    }
    final updatedItems = [...playlist.items, PlaylistItem.fromContent(item)];
    _playlists[index] = playlist.copyWith(
      items: updatedItems,
      updatedAtMillis: DateTime.now().millisecondsSinceEpoch,
    );
    notifyListeners();
    _persistPlaylists();
    return true;
  }

  bool removeFromPlaylist(String playlistId, String itemIdentity) {
    if (getPlaylistById(playlistId)?.readOnly == true) {
      return false;
    }
    final index = _playlists.indexWhere(
      (playlist) => playlist.id == playlistId,
    );
    if (index < 0) {
      return false;
    }
    final playlist = _playlists[index];
    final updatedItems = playlist.items
        .where((entry) => entry.identity != itemIdentity)
        .toList(growable: false);
    if (updatedItems.length == playlist.items.length) {
      return false;
    }
    _playlists[index] = playlist.copyWith(
      items: updatedItems,
      updatedAtMillis: DateTime.now().millisecondsSinceEpoch,
    );
    notifyListeners();
    _persistPlaylists();
    return true;
  }

  bool renamePlaylist(String playlistId, String newTitle) {
    if (getPlaylistById(playlistId)?.readOnly == true) {
      return false;
    }
    final index = _playlists.indexWhere(
      (playlist) => playlist.id == playlistId,
    );
    if (index < 0) {
      return false;
    }
    final trimmed = newTitle.trim();
    final safeTitle = trimmed.isEmpty ? 'Playlist ${index + 1}' : trimmed;
    final playlist = _playlists[index];
    if (playlist.title == safeTitle) {
      return false;
    }
    _playlists[index] = playlist.copyWith(
      title: safeTitle,
      updatedAtMillis: DateTime.now().millisecondsSinceEpoch,
    );
    notifyListeners();
    _persistPlaylists();
    return true;
  }

  void reorderPlaylistItem(String playlistId, int oldIndex, int newIndex) {
    if (getPlaylistById(playlistId)?.readOnly == true) {
      return;
    }
    final playlistIndex = _playlists.indexWhere(
      (playlist) => playlist.id == playlistId,
    );
    if (playlistIndex >= 0) {
      final playlist = _playlists[playlistIndex];
      final items = [...playlist.items];
      if (oldIndex < 0 ||
          oldIndex >= items.length ||
          newIndex < 0 ||
          newIndex > items.length) {
        return;
      }
      if (newIndex > oldIndex) {
        newIndex -= 1;
      }
      final item = items.removeAt(oldIndex);
      items.insert(newIndex, item);
      _playlists[playlistIndex] = playlist.copyWith(
        items: items,
        updatedAtMillis: DateTime.now().millisecondsSinceEpoch,
      );
      notifyListeners();
      _persistPlaylists();
    }
  }

  double resumePositionFor(
    ContentItem item, {
    PlaylistPlaybackContext? playlistContext,
  }) {
    if (_lastPlayedItem?.id != item.id) {
      return 0.0;
    }
    final savedPlaylistId = _lastPlayedPlaylistContext?.playlistId;
    final currentPlaylistId = playlistContext?.playlistId;
    if (savedPlaylistId != currentPlaylistId ||
        _lastPlayedPlaylistContext?.itemIndex != playlistContext?.itemIndex) {
      return 0.0;
    }
    final total = _lastPlayedDurationSeconds > 0
        ? _lastPlayedDurationSeconds
        : item.durationSeconds.toDouble();
    if (total <= 0 || _lastPlayedPositionSeconds <= 0) {
      return 0.0;
    }
    if (_lastPlayedPositionSeconds >= total - 0.5) {
      return 0.0;
    }
    return _lastPlayedPositionSeconds;
  }

  Future<void> updateLastPlayed(
    ContentItem item, {
    required double positionSeconds,
    double? durationSeconds,
    PlaylistPlaybackContext? playlistContext,
  }) async {
    final persistPlaylistContext = isTransientPlaybackContext(playlistContext)
        ? null
        : playlistContext;
    final normalizedPosition = positionSeconds.isFinite && positionSeconds > 0
        ? positionSeconds
        : 0.0;
    final normalizedDuration =
        durationSeconds != null &&
            durationSeconds.isFinite &&
            durationSeconds > 0
        ? durationSeconds
        : item.durationSeconds.toDouble();

    _lastPlayedItem = item;
    _lastPlayedPlaylistContext = playlistContext;
    _lastPlayedPositionSeconds = normalizedPosition;
    _lastPlayedDurationSeconds = normalizedDuration;
    _currentPlayingItem = item;
    notifyListeners();

    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_lastPlayedItemKey, jsonEncode(item.toJson()));
    await prefs.setDouble(_lastPlayedPositionKey, normalizedPosition);
    await prefs.setDouble(_lastPlayedDurationKey, normalizedDuration);
    if (persistPlaylistContext == null) {
      await prefs.remove(_lastPlayedPlaylistContextKey);
    } else {
      await prefs.setString(
        _lastPlayedPlaylistContextKey,
        jsonEncode(persistPlaylistContext.toJson()),
      );
    }
  }

  Future<void> _loadLastPlayed() async {
    final prefs = await SharedPreferences.getInstance();
    _playlistOnlyForKids = prefs.getBool(_playlistOnlyForKidsKey) ?? false;
    _quizEnabled = prefs.getBool(_quizEnabledKey) ?? true;
    _waitForQuizExplanationAudio =
        prefs.getBool(_waitForQuizExplanationAudioKey) ?? true;
    _quizAttempts = _quizAttemptsFromPrefs(prefs);
    final itemJson = prefs.getString(_lastPlayedItemKey);
    if (itemJson == null || itemJson.isEmpty) {
      notifyListeners();
      return;
    }
    try {
      final restoredItem = ContentItem.fromJson(
        jsonDecode(itemJson) as Map<String, dynamic>,
      );
      if (_isPersistableContent(restoredItem)) {
        _lastPlayedItem = restoredItem;
      } else {
        await prefs.remove(_lastPlayedItemKey);
        await prefs.remove(_lastPlayedPositionKey);
        await prefs.remove(_lastPlayedDurationKey);
        await prefs.remove(_lastPlayedPlaylistContextKey);
        _lastPlayedItem = null;
        _lastPlayedPlaylistContext = null;
        _lastPlayedPositionSeconds = 0.0;
        _lastPlayedDurationSeconds = 0.0;
        notifyListeners();
        return;
      }
      _lastPlayedPositionSeconds =
          prefs.getDouble(_lastPlayedPositionKey) ?? 0.0;
      _lastPlayedDurationSeconds =
          prefs.getDouble(_lastPlayedDurationKey) ?? 0.0;
      final playlistContextJson = prefs.getString(
        _lastPlayedPlaylistContextKey,
      );
      if (playlistContextJson != null && playlistContextJson.isNotEmpty) {
        _lastPlayedPlaylistContext = PlaylistPlaybackContext.fromJson(
          jsonDecode(playlistContextJson) as Map<String, dynamic>,
        );
      }
      notifyListeners();
    } catch (_) {
      // Ignore bad persisted state.
    }
  }

  Map<String, QuizAttemptResult> _quizAttemptsFromPrefs(
    SharedPreferences prefs,
  ) {
    final raw = prefs.getString(_quizAttemptsKey);
    if (raw == null || raw.isEmpty) {
      return const {};
    }
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) {
        return const {};
      }
      final attempts = <String, QuizAttemptResult>{};
      for (final entry in decoded.entries) {
        final value = entry.value;
        if (value is! Map) {
          continue;
        }
        final attempt = QuizAttemptResult.fromJson(
          value.cast<String, dynamic>(),
        );
        final key = attempt.storyKey.trim().isNotEmpty
            ? attempt.storyKey
            : entry.key.toString();
        if (key.isNotEmpty) {
          attempts[key] = attempt;
        }
      }
      return attempts;
    } catch (_) {
      return const {};
    }
  }

  Future<void> _persistQuizAttempts() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _quizAttemptsKey,
      jsonEncode(
        _quizAttempts.map(
          (storyKey, result) => MapEntry(storyKey, result.toJson()),
        ),
      ),
    );
  }

  Future<void> _loadContentEnvironment() async {
    _contentEnvironmentLoading = true;
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      final storedMode =
          prefs.getString(_contentEnvironmentModeKey) ?? 'production';
      final storedSandboxLabel = prefs.getString(_sandboxLabelKey) ?? '';
      final resolvedSandboxLabel = storedMode == 'sandbox'
          ? await _resolveSandboxLabel(storedSandboxLabel)
          : '';
      if (storedMode == 'sandbox' &&
          storedSandboxLabel.trim() != resolvedSandboxLabel) {
        await DeployedContentRepository.instance.clearAllDownloadedContent();
        _recentlyAddedItems = const [];
        _recentlyAddedLoading = true;
        _lastPlayedItem = null;
        _lastPlayedPlaylistContext = null;
        _lastPlayedPositionSeconds = 0.0;
        _lastPlayedDurationSeconds = 0.0;
        _currentPlayingItem = null;
      }
      await DeployedContentRepository.instance.setEnvironment(
        mode: storedMode,
        sandboxLabel: resolvedSandboxLabel,
      );
      _contentEnvironmentMode =
          storedMode == 'sandbox' && resolvedSandboxLabel.isNotEmpty
          ? 'sandbox'
          : 'production';
      _sandboxLabel = _contentEnvironmentMode == 'sandbox'
          ? resolvedSandboxLabel
          : '';
      if (_contentEnvironmentMode == 'sandbox') {
        await prefs.setString(_sandboxLabelKey, _sandboxLabel);
      } else {
        await prefs.remove(_sandboxLabelKey);
      }
      _catalogEpoch = prefs.getInt(_catalogEpochKey) ?? 0;
      _catalogIdentity = prefs.getString(_catalogIdentityKey) ?? '';
      _productionCategoryMode =
          prefs.getString(_productionCategoryModeKey) ?? 'static';
      await _refreshCatalogModeAndCategories(prefs: prefs);
      _scheduleRecentlyAddedRefresh();
      unawaited(_refreshEditorialPlaylists());
    } finally {
      _contentEnvironmentLoading = false;
      notifyListeners();
    }
  }

  Future<CustomerSession?> _validCustomerSession() async {
    var session = _customerSession;
    if (session == null || !session.isUsable) {
      return null;
    }
    if (!session.isExpired) {
      return session;
    }
    try {
      session = await _customerApiClient.refresh(session);
      _customerSession = session;
      _syncCustomerAccessToRepository();
      return session;
    } catch (error) {
      _customerSessionError = error.toString();
      final cachedProfile = await _customerApiClient.loadStoredProfile();
      if (cachedProfile != null && _isLikelyOfflineError(error)) {
        _customerProfile ??= cachedProfile;
        _syncCustomerAccessToRepository();
        notifyListeners();
        return session;
      }
      _customerSession = null;
      _customerProfile = null;
      _syncCustomerAccessToRepository();
      await _customerApiClient.clearSession();
      notifyListeners();
      return null;
    }
  }

  bool _isLikelyOfflineError(Object error) {
    final text = error.toString().toLowerCase();
    return text.contains('socketexception') ||
        text.contains('clientexception') ||
        text.contains('failed host lookup') ||
        text.contains('no address associated') ||
        text.contains('network is unreachable') ||
        text.contains('connection refused') ||
        text.contains('connection timed out') ||
        text.contains('connection reset') ||
        text.contains('operation timed out');
  }

  Future<void> _refreshCatalogModeAndCategories({
    required SharedPreferences prefs,
    bool resetAlreadyApplied = false,
  }) async {
    try {
      final meta = await DeployedContentRepository.instance.loadCatalogMeta();
      final remoteEpoch = ((meta['catalog_epoch'] ?? 0) as num).toInt();
      final remoteIdentity = DeployedContentRepository.instance.catalogIdentity
          .trim();
      final remoteCategoryMode = ((meta['category_mode'] ?? 'dynamic')
          .toString()
          .trim()
          .toLowerCase());
      final identityChanged =
          remoteIdentity.isNotEmpty && remoteIdentity != _catalogIdentity;
      final epochChanged = remoteEpoch > 0 && remoteEpoch != _catalogEpoch;

      if (!sandboxMode &&
          (identityChanged || (remoteIdentity.isEmpty && epochChanged)) &&
          !resetAlreadyApplied) {
        await DeployedContentRepository.instance.clearAllDownloadedContent();
      }
      if (remoteEpoch > 0) {
        _catalogEpoch = remoteEpoch;
        await prefs.setInt(_catalogEpochKey, remoteEpoch);
      }
      if (remoteIdentity.isNotEmpty) {
        _catalogIdentity = remoteIdentity;
        await prefs.setString(_catalogIdentityKey, remoteIdentity);
      }
      if (!sandboxMode) {
        _productionCategoryMode = remoteCategoryMode == 'dynamic'
            ? 'dynamic'
            : 'static';
        await prefs.setString(
          _productionCategoryModeKey,
          _productionCategoryMode,
        );
      }
    } catch (_) {
      // Keep the last known production mode/epoch if metadata is temporarily unavailable.
    }

    if (sandboxMode || productionUsesDynamicCategories) {
      try {
        await _refreshRemoteSandboxCategories();
      } catch (_) {
        _remoteStoryCategories['english'] = const [];
        _remoteStoryCategories['hindi'] = const [];
        _remoteRhymeCategories['english'] = const [];
      }
    } else {
      _remoteStoryCategories['english'] = const [];
      _remoteStoryCategories['hindi'] = const [];
      _remoteRhymeCategories['english'] = const [];
    }
  }

  Future<Category> _categoryFromRemoteSummary(
    Map<String, dynamic> item,
    String type,
    String language,
  ) async {
    final label = (item['name'] ?? '').toString().trim();
    final serverCategoryId = ((item['id'] ?? 0) as num).toInt();
    final normalizedId = label
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9]+'), '_')
        .replaceAll(RegExp(r'_+'), '_')
        .replaceAll(RegExp(r'^_|_$'), '');
    final iconUrl =
        (item['category_icon_url'] ?? item['category_thumbnail_url'] ?? '')
            .toString()
            .trim();
    final cachedIconPath = await DeployedContentRepository.instance
        .cachedCatalogImagePath(
          url: iconUrl,
          namespace: 'category_icons/$type/$language',
          cacheKey: '$serverCategoryId',
        );
    return Category(
      id: normalizedId.isEmpty ? '$type-$serverCategoryId' : normalizedId,
      label: label.isEmpty ? 'Category $serverCategoryId' : label,
      type: type,
      language: language,
      serverCategoryId: serverCategoryId,
      icon: CategoryRegistry.fallbackIconFor(normalizedId, type),
      assetPath: cachedIconPath,
      iconUrl: cachedIconPath == null ? iconUrl : null,
    );
  }

  Future<void> _refreshRemoteSandboxCategories() async {
    final storyEnglish = await DeployedContentRepository.instance
        .loadRemoteCategories(type: 'story', language: 'english');
    final rhymeEnglish = await DeployedContentRepository.instance
        .loadRemoteCategories(type: 'rhyme', language: 'english');

    _remoteStoryCategories['english'] = await Future.wait(
      storyEnglish.map((item) {
        return _categoryFromRemoteSummary(item, 'story', 'english');
      }),
    );
    _remoteStoryCategories['hindi'] = const [];
    _remoteRhymeCategories['english'] = await Future.wait(
      rhymeEnglish.map((item) {
        return _categoryFromRemoteSummary(item, 'rhyme', 'english');
      }),
    );
  }

  Future<void> _loadPlaylists() async {
    final prefs = await SharedPreferences.getInstance();
    final payload = prefs.getString(_playlistsKey);
    if (payload == null || payload.isEmpty) {
      return;
    }
    try {
      final decoded = jsonDecode(payload) as List<dynamic>;
      final loaded = decoded
          .whereType<Map<dynamic, dynamic>>()
          .map((entry) => Playlist.fromJson(entry.cast<String, dynamic>()))
          .toList(growable: false);
      if (loaded.isEmpty) {
        return;
      }
      var changed = false;
      final sanitized = loaded
          .take(kMaxPlaylists)
          .map((playlist) {
            final filteredItems = playlist.items
                .where((entry) => _isPersistableContent(entry.content))
                .toList(growable: false);
            if (filteredItems.length != playlist.items.length) {
              changed = true;
            }
            return playlist.copyWith(items: filteredItems);
          })
          .toList(growable: false);
      _playlists = sanitized;
      notifyListeners();
      if (changed) {
        await _persistPlaylists();
      }
    } catch (_) {
      // Ignore bad persisted playlists.
    }
  }

  bool _isPersistableContent(ContentItem item) {
    return item.serverContentId > 0 && item.serverCategoryId > 0;
  }

  Future<void> _persistPlaylists() async {
    final prefs = await SharedPreferences.getInstance();
    final payload = _playlists
        .take(kMaxPlaylists)
        .map(
          (playlist) => playlist.copyWith(
            items: playlist.items
                .take(playlist.maxItems)
                .toList(growable: false),
          ),
        )
        .map((playlist) => playlist.toJson())
        .toList(growable: false);
    await prefs.setString(_playlistsKey, jsonEncode(payload));
  }

  Future<void> _refreshEditorialPlaylists({int retries = 4}) async {
    try {
      final playlists = await DeployedContentRepository.instance
          .loadEditorialPlaylists();
      _editorialPlaylists = playlists;
      notifyListeners();
    } catch (_) {
      if (retries > 0) {
        Timer(
          const Duration(seconds: 10),
          () => _refreshEditorialPlaylists(retries: retries - 1),
        );
      }
    }
  }

  void _scheduleRecentlyAddedRefresh({
    Duration delay = const Duration(seconds: 2),
    int retries = 8,
  }) {
    Timer(delay, () => _refreshRecentlyAddedWhenIdle(retries: retries));
  }

  Future<void> _refreshRecentlyAddedWhenIdle({int retries = 8}) async {
    if (DeployedContentRepository.instance.hasActiveDownloads) {
      if (retries > 0) {
        _scheduleRecentlyAddedRefresh(
          delay: const Duration(seconds: 5),
          retries: retries - 1,
        );
      }
      return;
    }
    try {
      final items = await DeployedContentRepository.instance
          .loadRecentlyAddedItems();
      _recentlyAddedItems = items.take(10).toList(growable: false);
      _recentlyAddedLoading = false;
      notifyListeners();
    } catch (_) {
      _recentlyAddedLoading = false;
      notifyListeners();
      if (retries > 0) {
        _scheduleRecentlyAddedRefresh(
          delay: const Duration(seconds: 10),
          retries: retries - 1,
        );
      }
    }
  }
}
