import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../api/quizmaster_api.dart';
import '../storage/settings_store.dart';

typedef ApiFactory = QuizmasterApi Function(String baseUrl, String token);

class PipelineRole {
  const PipelineRole({
    required this.id,
    required this.label,
    required this.providerField,
    required this.modelField,
    required this.allowedTypes,
  });

  final String id;
  final String label;
  final String providerField;
  final String? modelField;
  final Set<String> allowedTypes;
}

const pipelineRoles = <PipelineRole>[
  PipelineRole(
    id: 'question',
    label: 'Question generation',
    providerField: 'question_provider',
    modelField: 'question_model',
    allowedTypes: {'openai_images'},
  ),
  PipelineRole(
    id: 'qwen',
    label: 'Planning and set selection',
    providerField: 'qwen_provider',
    modelField: 'qwen_model',
    allowedTypes: {'openai_compatible_llm'},
  ),
  PipelineRole(
    id: 'background',
    label: 'Background images',
    providerField: 'background_provider',
    modelField: 'background_model',
    allowedTypes: {'openai_images', 'imagestudio'},
  ),
  PipelineRole(
    id: 'tile',
    label: 'Quiz tile images',
    providerField: 'tile_provider',
    modelField: 'tile_model',
    allowedTypes: {'openai_images', 'imagestudio'},
  ),
  PipelineRole(
    id: 'answer',
    label: 'Answer images',
    providerField: 'answer_provider',
    modelField: 'answer_model',
    allowedTypes: {'openai_images', 'imagestudio'},
  ),
  PipelineRole(
    id: 'audio',
    label: 'Narration',
    providerField: 'audio_provider',
    modelField: null,
    allowedTypes: {'vibevoice'},
  ),
];

class AppController extends ChangeNotifier {
  AppController({required this.settingsStore, ApiFactory? apiFactory})
    : _apiFactory =
          apiFactory ??
          ((baseUrl, token) => QuizmasterApi(baseUrl: baseUrl, token: token));

  static const defaultBaseUrl = 'https://quizmaster.photovault.live';
  static const buildLabel = 'Build 2';
  static const compiledBaseUrl = String.fromEnvironment(
    'QUIZMASTER_API_URL',
    defaultValue: defaultBaseUrl,
  );
  static const compiledToken = String.fromEnvironment('QUIZMASTER_API_TOKEN');
  static const _urlKey = 'quizmaster_api_url';
  static const _tokenKey = 'quizmaster_api_token';
  static const _routingKey = 'quizmaster_pipeline_routing';
  static const _lastJobKey = 'quizmaster_last_job';

  final SettingsStore settingsStore;
  final ApiFactory _apiFactory;

  QuizmasterApi? _api;
  Timer? _pollTimer;
  bool _refreshingStatus = false;

  int selectedScreen = 0;
  String baseUrl = defaultBaseUrl;
  String token = '';
  bool initializing = true;
  bool connecting = false;
  bool connected = false;
  bool loadingProviders = false;
  bool startingPipeline = false;
  String? errorMessage;
  String? noticeMessage;

  List<Map<String, dynamic>> providers = [];
  Map<String, dynamic> pipelineOptions = {};
  Map<String, String> providerSelections = {};
  Map<String, String> modelSelections = {};
  String backgroundGuidance = '';
  Map<String, dynamic>? currentJob;
  List<Map<String, dynamic>> recentJobs = [];
  List<Map<String, dynamic>> bundles = [];
  Map<String, dynamic> lockState = const {'busy': false, 'holder': null};
  String? lastJobId;

  bool get pipelineBusy => lockState['busy'] == true;
  bool get routingReady => pipelineRoles.every(
    (role) => (providerSelections[role.providerField] ?? '').isNotEmpty,
  );

  Future<void> initialize() async {
    final storedUrl = await settingsStore.read(_urlKey);
    baseUrl = storedUrl?.trim().isNotEmpty == true
        ? storedUrl!.trim()
        : compiledBaseUrl;
    token = await settingsStore.read(_tokenKey) ?? compiledToken;
    lastJobId = await settingsStore.read(_lastJobKey);
    initializing = false;
    notifyListeners();
    if (token.trim().isNotEmpty) {
      await connect(silent: true);
    }
  }

  Future<bool> saveConnection({
    required String url,
    required String apiToken,
  }) async {
    final normalized = url.trim().replaceFirst(RegExp(r'/+$'), '');
    if (!normalized.startsWith('https://') &&
        !normalized.startsWith('http://')) {
      _setError('Enter a complete HTTP or HTTPS server URL.');
      return false;
    }
    baseUrl = normalized;
    token = apiToken.trim();
    await settingsStore.write(_urlKey, baseUrl);
    await settingsStore.write(_tokenKey, token);
    return connect();
  }

  Future<bool> connect({bool silent = false}) async {
    connecting = true;
    errorMessage = null;
    notifyListeners();
    _api?.close();
    _api = _apiFactory(baseUrl, token);
    try {
      final health = await _healthWithDnsRetry();
      if (health['status'] != 'ok') {
        throw const ApiException('Quizmaster API is not ready.');
      }
      await refreshProviders();
      await refreshStatus(silent: true);
      connected = true;
      if (silent && (pipelineBusy || lastJobId != null)) selectedScreen = 2;
      if (!silent) noticeMessage = 'Connected to Quizmaster.';
      _startPolling();
      return true;
    } catch (error) {
      connected = false;
      _setError(_message(error));
      return false;
    } finally {
      connecting = false;
      notifyListeners();
    }
  }

  Future<Map<String, dynamic>> _healthWithDnsRetry() async {
    Object? lastError;
    for (var attempt = 0; attempt < 3; attempt++) {
      try {
        return await _api!.health();
      } catch (error) {
        lastError = error;
        if (!_isDnsError(error) || attempt == 2) {
          rethrow;
        }
        await Future<void>.delayed(const Duration(seconds: 1));
      }
    }
    throw lastError!;
  }

  Future<void> refreshProviders() async {
    if (_api == null) return;
    loadingProviders = true;
    notifyListeners();
    try {
      final responses = await Future.wait([
        _api!.providers(),
        _api!.pipelineOptions(),
      ]);
      providers = _mapList(responses[0]['providers']);
      pipelineOptions = responses[1];
      await _restoreRouting();
      errorMessage = null;
    } catch (error) {
      _setError(_message(error));
      rethrow;
    } finally {
      loadingProviders = false;
      notifyListeners();
    }
  }

  Future<void> _restoreRouting() async {
    final defaults = _stringMap(
      (pipelineOptions['defaults'] as Map?)?['providers'],
    );
    final storedRaw = await settingsStore.read(_routingKey);
    Map<String, dynamic> stored = {};
    if (storedRaw != null) {
      try {
        stored = jsonDecode(storedRaw) as Map<String, dynamic>;
      } on Object {
        stored = {};
      }
    }
    providerSelections = {
      for (final role in pipelineRoles)
        role.providerField:
            stored[role.providerField]?.toString() ??
            defaults[role.providerField] ??
            '',
    };
    modelSelections = {
      for (final role in pipelineRoles)
        if (role.modelField != null)
          role.modelField!:
              stored[role.modelField]?.toString() ??
              defaults[role.modelField!] ??
              '',
    };
    backgroundGuidance = stored['background_guidance']?.toString() ?? '';
    for (final role in pipelineRoles) {
      final valid = providersForRole(
        role,
      ).any((item) => item['id'] == providerSelections[role.providerField]);
      if (!valid) {
        final candidates = providersForRole(role);
        providerSelections[role.providerField] = candidates.isEmpty
            ? ''
            : candidates.first['id'].toString();
      }
    }
    await _persistRouting();
  }

  List<Map<String, dynamic>> providersForRole(PipelineRole role) => providers
      .where(
        (item) =>
            item['enabled'] == true &&
            role.allowedTypes.contains(item['provider_type']),
      )
      .toList();

  Map<String, dynamic>? providerById(String? id) {
    if (id == null) return null;
    for (final provider in providers) {
      if (provider['id'] == id) return provider;
    }
    return null;
  }

  List<String> modelsForProvider(String? id) {
    final provider = providerById(id);
    if (provider == null) return [];
    final discovered = (provider['discovered_models'] as List? ?? const [])
        .map((item) => item.toString())
        .where((item) => item.isNotEmpty)
        .toSet();
    final configured = provider['default_model']?.toString();
    if (configured != null && configured.isNotEmpty) discovered.add(configured);
    return discovered.toList()..sort();
  }

  List<String> modelsForRole(PipelineRole role) {
    if (role.id == 'question') {
      return const [];
    }
    return modelsForProvider(providerSelections[role.providerField]);
  }

  Future<void> setRoleProvider(PipelineRole role, String providerId) async {
    providerSelections[role.providerField] = providerId;
    if (role.modelField != null) {
      final models = modelsForProvider(providerId);
      final defaults = _stringMap(
        (pipelineOptions['defaults'] as Map?)?['providers'],
      );
      final configured = role.id == 'question'
          ? defaults[role.modelField!]
          : providerById(providerId)?['default_model']?.toString() ??
                defaults[role.modelField!];
      modelSelections[role.modelField!] =
          configured ??
          modelSelections[role.modelField!] ??
          (models.isEmpty ? '' : models.first);
    }
    await _persistRouting();
    notifyListeners();
  }

  Future<void> setRoleModel(PipelineRole role, String model) async {
    if (role.modelField == null) return;
    modelSelections[role.modelField!] = model.trim();
    await _persistRouting();
  }

  Future<void> setBackgroundGuidance(String value) async {
    backgroundGuidance = value.trim();
    await _persistRouting();
  }

  Future<void> _persistRouting() => settingsStore.write(
    _routingKey,
    jsonEncode({
      ...providerSelections,
      ...modelSelections,
      'background_guidance': backgroundGuidance,
    }),
  );

  Future<bool> prepareRun() async {
    if (!connected && !await connect()) return false;
    await refreshStatus(silent: true);
    if (pipelineBusy) {
      selectedScreen = 2;
      noticeMessage =
          'Another generation is running. Showing its current status.';
      notifyListeners();
      return false;
    }
    if (!routingReady) {
      _setError('Choose a configured provider for every pipeline role.');
      return false;
    }
    selectedScreen = 1;
    notifyListeners();
    return true;
  }

  Future<bool> startGeneration({
    required Map<String, dynamic> metadata,
    required Map<String, dynamic> settings,
  }) async {
    if (_api == null || startingPipeline) return false;
    if (pipelineBusy) {
      _setError('Another category is currently being generated.');
      return false;
    }
    final selectedProviders = <String, dynamic>{...providerSelections};
    for (final entry in modelSelections.entries) {
      selectedProviders[entry.key] = entry.value.trim().isEmpty
          ? null
          : entry.value.trim();
    }
    settings['background_guidance'] = backgroundGuidance.trim().isEmpty
        ? null
        : backgroundGuidance.trim();
    startingPipeline = true;
    errorMessage = null;
    notifyListeners();
    try {
      final job = await _api!.startPipeline({
        'metadata': metadata,
        'providers': selectedProviders,
        'settings': settings,
      });
      lastJobId = job['id'].toString();
      await settingsStore.write(_lastJobKey, lastJobId!);
      currentJob = job;
      selectedScreen = 2;
      noticeMessage = 'Generation started.';
      await refreshStatus(silent: true);
      return true;
    } catch (error) {
      _setError(_message(error));
      return false;
    } finally {
      startingPipeline = false;
      notifyListeners();
    }
  }

  Future<void> refreshStatus({bool silent = false}) async {
    if (_api == null || _refreshingStatus) return;
    _refreshingStatus = true;
    try {
      final results = await Future.wait([_api!.dashboard(), _api!.pipelines()]);
      final dashboard = results[0];
      final generation = dashboard['current_generation'] as Map? ?? const {};
      lockState = Map<String, dynamic>.from(
        generation['lock'] as Map? ?? const {'busy': false, 'holder': null},
      );
      bundles = _mapList(dashboard['bundles']);
      recentJobs = _mapList(results[1]['jobs']);
      if (generation['job'] is Map) {
        currentJob = Map<String, dynamic>.from(generation['job'] as Map);
        final activeId = currentJob?['id']?.toString();
        if (activeId != null && activeId.isNotEmpty && activeId != lastJobId) {
          lastJobId = activeId;
          await settingsStore.write(_lastJobKey, activeId);
        }
      } else if (lastJobId != null && lastJobId!.isNotEmpty) {
        try {
          currentJob = await _api!.pipelineJob(lastJobId!);
        } on ApiException catch (error) {
          if (error.statusCode != 404) rethrow;
        }
      } else if (recentJobs.isNotEmpty) {
        currentJob = recentJobs.first;
      }
      if (!silent) noticeMessage = 'Production status refreshed.';
      errorMessage = null;
    } catch (error) {
      if (!silent) _setError(_message(error));
    } finally {
      _refreshingStatus = false;
      notifyListeners();
    }
  }

  Future<bool> deployBundle(String slug, {int? version}) async {
    if (_api == null || pipelineBusy) {
      _setError('Wait for the current generation to finish before deploying.');
      return false;
    }
    try {
      await _api!.deploy(slug, version: version);
      await refreshStatus(silent: true);
      noticeMessage = 'Bundle deployed.';
      notifyListeners();
      return true;
    } catch (error) {
      _setError(_message(error));
      return false;
    }
  }

  Future<void> selectJob(String jobId) async {
    lastJobId = jobId;
    await settingsStore.write(_lastJobKey, jobId);
    if (_api != null) {
      try {
        currentJob = await _api!.pipelineJob(jobId);
      } catch (error) {
        _setError(_message(error));
      }
    }
    selectedScreen = 2;
    notifyListeners();
  }

  void selectScreen(int index) {
    if (selectedScreen == index) return;
    selectedScreen = index;
    notifyListeners();
    if (index == 2) unawaited(refreshStatus(silent: true));
  }

  String? takeNotice() {
    final value = noticeMessage;
    noticeMessage = null;
    return value;
  }

  void clearError() {
    errorMessage = null;
    notifyListeners();
  }

  void _startPolling() {
    _pollTimer?.cancel();
    _pollTimer = Timer.periodic(
      const Duration(seconds: 3),
      (_) => unawaited(refreshStatus(silent: true)),
    );
  }

  void _setError(String message) {
    errorMessage = message;
    noticeMessage = null;
    notifyListeners();
  }

  static bool _isDnsError(Object error) {
    final message = error.toString().toLowerCase();
    return message.contains('failed host lookup') ||
        message.contains('no address associated with hostname');
  }

  static String _message(Object error) {
    if (_isDnsError(error)) {
      return 'DNS lookup failed. Confirm the API URL opens on this phone, then reconnect '
          'Wi-Fi, mobile data, or the VPN and try again.';
    }
    return error is ApiException
        ? error.message
        : error.toString().replaceFirst('Exception: ', '');
  }

  static List<Map<String, dynamic>> _mapList(dynamic value) =>
      (value as List? ?? const [])
          .whereType<Map>()
          .map((item) => Map<String, dynamic>.from(item))
          .toList();

  static Map<String, String> _stringMap(dynamic value) {
    if (value is! Map) return {};
    return {
      for (final entry in value.entries)
        if (entry.value != null) entry.key.toString(): entry.value.toString(),
    };
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    _api?.close();
    super.dispose();
  }
}
