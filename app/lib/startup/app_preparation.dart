import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../voice/local_pocket_tts.dart';
import '../voice/persona_asset_cache.dart';
import '../voice/voice_model_assets.dart';
import 'android_device_performance.dart';
import 'benchmark_preferences.dart';

const int _benchmarkVersion = 7;
const Duration _benchmarkBudget = Duration(seconds: 60);
const double _maximumFirstAudioP95Ms = 1500;
const double _maximumWarmRtfP95 = 0.80;
const double _maximumSustainedRtfP95 = 0.85;
const double _maximumThermalDegradation = 0.35;
const double _maximumProcessMemoryRatio = 0.25;

class DeviceTtsBenchmarkThresholds {
  const DeviceTtsBenchmarkThresholds({
    required this.benchmarkVersion,
    required this.benchmarkBudget,
    required this.maximumFirstAudioP95Ms,
    required this.maximumWarmRtfP95,
    required this.maximumSustainedRtfP95,
    required this.maximumThermalDegradation,
    required this.maximumProcessMemoryRatio,
    required this.maximumGenerationFailures,
    required this.minimumAvailableMemoryBytes,
  });

  final int benchmarkVersion;
  final Duration benchmarkBudget;
  final double maximumFirstAudioP95Ms;
  final double maximumWarmRtfP95;
  final double maximumSustainedRtfP95;
  final double maximumThermalDegradation;
  final double maximumProcessMemoryRatio;
  final int maximumGenerationFailures;
  final int minimumAvailableMemoryBytes;

  factory DeviceTtsBenchmarkThresholds.fromJson(Map<String, dynamic> json) {
    return deviceTtsBenchmarkThresholds.copyWith(
      maximumFirstAudioP95Ms: (json['maximum_first_audio_p95_ms'] as num?)
          ?.toDouble(),
      maximumWarmRtfP95: (json['maximum_warm_rtf_p95'] as num?)?.toDouble(),
      maximumSustainedRtfP95: (json['maximum_sustained_rtf_p95'] as num?)
          ?.toDouble(),
      maximumThermalDegradation: (json['maximum_thermal_degradation'] as num?)
          ?.toDouble(),
      maximumProcessMemoryRatio: (json['maximum_process_memory_ratio'] as num?)
          ?.toDouble(),
      maximumGenerationFailures: (json['maximum_generation_failures'] as num?)
          ?.toInt(),
      minimumAvailableMemoryBytes:
          (json['minimum_available_memory_bytes'] as num?)?.toInt(),
    );
  }

  DeviceTtsBenchmarkThresholds copyWith({
    double? maximumFirstAudioP95Ms,
    double? maximumWarmRtfP95,
    double? maximumSustainedRtfP95,
    double? maximumThermalDegradation,
    double? maximumProcessMemoryRatio,
    int? maximumGenerationFailures,
    int? minimumAvailableMemoryBytes,
  }) {
    return DeviceTtsBenchmarkThresholds(
      benchmarkVersion: benchmarkVersion,
      benchmarkBudget: benchmarkBudget,
      maximumFirstAudioP95Ms:
          (maximumFirstAudioP95Ms ?? this.maximumFirstAudioP95Ms)
              .clamp(500, 6000)
              .toDouble(),
      maximumWarmRtfP95: (maximumWarmRtfP95 ?? this.maximumWarmRtfP95)
          .clamp(0.30, 1.50)
          .toDouble(),
      maximumSustainedRtfP95:
          (maximumSustainedRtfP95 ?? this.maximumSustainedRtfP95)
              .clamp(0.30, 2.00)
              .toDouble(),
      maximumThermalDegradation:
          (maximumThermalDegradation ?? this.maximumThermalDegradation)
              .clamp(0.05, 1.00)
              .toDouble(),
      maximumProcessMemoryRatio:
          (maximumProcessMemoryRatio ?? this.maximumProcessMemoryRatio)
              .clamp(0.10, 0.80)
              .toDouble(),
      maximumGenerationFailures:
          (maximumGenerationFailures ?? this.maximumGenerationFailures)
              .clamp(0, 3)
              .toInt(),
      minimumAvailableMemoryBytes:
          (minimumAvailableMemoryBytes ?? this.minimumAvailableMemoryBytes)
              .clamp(128 * 1024 * 1024, 2 * 1024 * 1024 * 1024)
              .toInt(),
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
    'benchmark_version': benchmarkVersion,
    'maximum_first_audio_p95_ms': maximumFirstAudioP95Ms,
    'maximum_warm_rtf_p95': maximumWarmRtfP95,
    'maximum_sustained_rtf_p95': maximumSustainedRtfP95,
    'maximum_thermal_degradation': maximumThermalDegradation,
    'maximum_process_memory_ratio': maximumProcessMemoryRatio,
    'maximum_generation_failures': maximumGenerationFailures,
    'minimum_available_memory_bytes': minimumAvailableMemoryBytes,
  };

  String get cacheKey => <Object>[
    benchmarkVersion,
    maximumWarmRtfP95.toStringAsFixed(2),
    maximumSustainedRtfP95.toStringAsFixed(2),
    maximumThermalDegradation.toStringAsFixed(2),
    maximumProcessMemoryRatio.toStringAsFixed(2),
    maximumGenerationFailures,
    minimumAvailableMemoryBytes,
  ].join(':');
}

const DeviceTtsBenchmarkThresholds deviceTtsBenchmarkThresholds =
    DeviceTtsBenchmarkThresholds(
      benchmarkVersion: _benchmarkVersion,
      benchmarkBudget: _benchmarkBudget,
      maximumFirstAudioP95Ms: _maximumFirstAudioP95Ms,
      maximumWarmRtfP95: _maximumWarmRtfP95,
      maximumSustainedRtfP95: _maximumSustainedRtfP95,
      maximumThermalDegradation: _maximumThermalDegradation,
      maximumProcessMemoryRatio: _maximumProcessMemoryRatio,
      maximumGenerationFailures: 0,
      minimumAvailableMemoryBytes: 512 * 1024 * 1024,
    );

Future<DeviceTtsBenchmarkThresholds> loadDeviceTtsBenchmarkThresholds() async {
  final File file = await _deviceTtsBenchmarkThresholdFile();
  if (!await file.exists()) {
    return deviceTtsBenchmarkThresholds;
  }
  try {
    final Object? decoded = jsonDecode(await file.readAsString());
    if (decoded is Map<String, dynamic>) {
      return DeviceTtsBenchmarkThresholds.fromJson(decoded);
    }
  } catch (_) {
    // Fall back to conservative defaults if the local config is corrupt.
  }
  return deviceTtsBenchmarkThresholds;
}

Future<void> saveDeviceTtsBenchmarkThresholds(
  DeviceTtsBenchmarkThresholds thresholds,
) async {
  final File file = await _deviceTtsBenchmarkThresholdFile();
  await file.parent.create(recursive: true);
  await file.writeAsString(
    const JsonEncoder.withIndent('  ').convert(thresholds.toJson()),
    flush: true,
  );
}

Future<File> _deviceTtsBenchmarkThresholdFile() async {
  final Directory supportDir = await getApplicationSupportDirectory();
  return File('${supportDir.path}/config/tts_benchmark_gates.json');
}

enum DeviceTtsCapabilityStatus {
  localPreferred,
  unsupported,
  verificationDeferred,
}

enum AppPreparationState { checking, running, result, ready }

class DeviceTtsBenchmarkReport {
  const DeviceTtsBenchmarkReport({
    required this.status,
    required this.cacheKey,
    required this.appVersion,
    required this.reason,
    required this.selectedThreads,
    required this.modelInitializationMs,
    required this.firstAudioP95Ms,
    required this.warmRtfP95,
    required this.sustainedRtfP95,
    required this.thermalDegradation,
    required this.peakProcessMemoryRatio,
    required this.generationFailures,
    required this.completedAt,
  });

  factory DeviceTtsBenchmarkReport.fromJson(Map<String, dynamic> json) {
    return DeviceTtsBenchmarkReport(
      status: DeviceTtsCapabilityStatus.values.firstWhere(
        (DeviceTtsCapabilityStatus value) => value.name == json['status'],
        orElse: () => DeviceTtsCapabilityStatus.unsupported,
      ),
      cacheKey: json['cache_key']?.toString() ?? '',
      appVersion: json['app_version']?.toString() ?? 'unknown',
      reason: json['reason']?.toString() ?? '',
      selectedThreads: (json['selected_threads'] as num?)?.toInt() ?? 2,
      modelInitializationMs:
          (json['model_initialization_ms'] as num?)?.toDouble() ?? 0,
      firstAudioP95Ms: (json['first_audio_p95_ms'] as num?)?.toDouble() ?? 0,
      warmRtfP95: (json['warm_rtf_p95'] as num?)?.toDouble() ?? 0,
      sustainedRtfP95: (json['sustained_rtf_p95'] as num?)?.toDouble() ?? 0,
      thermalDegradation:
          (json['thermal_degradation'] as num?)?.toDouble() ?? 0,
      peakProcessMemoryRatio:
          (json['peak_process_memory_ratio'] as num?)?.toDouble() ?? 0,
      generationFailures: (json['generation_failures'] as num?)?.toInt() ?? 0,
      completedAt:
          DateTime.tryParse(json['completed_at']?.toString() ?? '') ??
          DateTime.fromMillisecondsSinceEpoch(0),
    );
  }

  final DeviceTtsCapabilityStatus status;
  final String cacheKey;
  final String appVersion;
  final String reason;
  final int selectedThreads;
  final double modelInitializationMs;
  final double firstAudioP95Ms;
  final double warmRtfP95;
  final double sustainedRtfP95;
  final double thermalDegradation;
  final double peakProcessMemoryRatio;
  final int generationFailures;
  final DateTime completedAt;

  bool get enablesLocalTts =>
      status == DeviceTtsCapabilityStatus.localPreferred;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'status': status.name,
    'cache_key': cacheKey,
    'reason': reason,
    'benchmark_version': _benchmarkVersion,
    'app_version': appVersion,
    'model_id': pocketTtsModelId,
    'runtime_version': pocketTtsRuntimeId,
    'selected_threads': selectedThreads,
    'model_initialization_ms': modelInitializationMs,
    'first_audio_p95_ms': firstAudioP95Ms,
    'warm_rtf_p95': warmRtfP95,
    'sustained_rtf_p95': sustainedRtfP95,
    'thermal_degradation': thermalDegradation,
    'peak_process_memory_ratio': peakProcessMemoryRatio,
    'generation_failures': generationFailures,
    'completed_at': completedAt.toUtc().toIso8601String(),
  };
}

class DeviceTtsBenchmarkDecision {
  const DeviceTtsBenchmarkDecision({
    required this.status,
    required this.reason,
  });

  final DeviceTtsCapabilityStatus status;
  final String reason;
}

DeviceTtsBenchmarkDecision evaluateDeviceTtsBenchmark({
  required double firstAudioP95Ms,
  required double warmRtfP95,
  required double sustainedRtfP95,
  required double thermalDegradation,
  required bool thermallyConstrained,
  required double peakProcessMemoryRatio,
  required int generationFailures,
  DeviceTtsBenchmarkThresholds thresholds = deviceTtsBenchmarkThresholds,
}) {
  // PocketTTS emits a full generated block, so this is useful telemetry but
  // not a reliable capability gate for user-perceived playback latency.
  final double _ = firstAudioP95Ms;
  final List<String> failures = <String>[
    if (warmRtfP95 > thresholds.maximumWarmRtfP95)
      'warm voice generation was too slow',
    if (sustainedRtfP95 > thresholds.maximumSustainedRtfP95)
      'sustained voice generation was too slow',
    if (thermalDegradation > thresholds.maximumThermalDegradation ||
        thermallyConstrained)
      'voice performance degraded under sustained load',
    if (peakProcessMemoryRatio > thresholds.maximumProcessMemoryRatio)
      'local voice generation used too much memory',
    if (generationFailures > thresholds.maximumGenerationFailures)
      'voice generation failed',
  ];
  return DeviceTtsBenchmarkDecision(
    status: failures.isEmpty
        ? DeviceTtsCapabilityStatus.localPreferred
        : DeviceTtsCapabilityStatus.unsupported,
    reason: failures.isEmpty
        ? 'Local cloned-voice generation passed.'
        : failures.join('; '),
  );
}

String _formatModelDownloadBytes(int bytes) {
  if (bytes < 1024) {
    return '$bytes B';
  }
  final double kb = bytes / 1024;
  if (kb < 1024) {
    return '${kb.toStringAsFixed(1)} KB';
  }
  final double mb = kb / 1024;
  if (mb < 1024) {
    return '${mb.toStringAsFixed(1)} MB';
  }
  return '${(mb / 1024).toStringAsFixed(2)} GB';
}

class AppPreparationController extends ChangeNotifier {
  static const String _reportPreferenceKey =
      'storyvault_device_benchmark_report_v2';
  static const String _runningPreferenceKey =
      'storyvault_device_benchmark_running_v3';
  static const String _phasePreferenceKey =
      'storyvault_device_benchmark_phase_v1';

  AppPreparationController()
    : _state = Platform.isAndroid || Platform.isIOS
          ? AppPreparationState.checking
          : AppPreparationState.ready;

  static Future<DeviceTtsBenchmarkReport?> loadStoredReport() async {
    final SharedPreferences preferences = await SharedPreferences.getInstance();
    final String? storedJson = preferences.getString(_reportPreferenceKey);
    if (storedJson == null) {
      return null;
    }
    try {
      return DeviceTtsBenchmarkReport.fromJson(
        jsonDecode(storedJson) as Map<String, dynamic>,
      );
    } catch (_) {
      return null;
    }
  }

  AppPreparationState _state;
  DeviceTtsBenchmarkReport? _report;
  String _phaseLabel = 'Checking this device';
  double _progress = 0;
  int _remainingSeconds = _benchmarkBudget.inSeconds;
  Timer? _countdownTimer;
  DeviceTtsBenchmarkRunner? _activeRunner;
  final Map<String, String> _liveMetrics = <String, String>{};
  bool _countdownActive = false;
  bool _modelAssetDownloadActive = false;
  bool _personaAssetDownloadActive = false;
  double _modelAssetDownloadFraction = 0;
  double _personaAssetDownloadFraction = 0;
  int _modelAssetDownloadedBytes = 0;
  int _modelAssetTotalBytes = 0;
  String _modelAssetFileLabel = '';
  String _personaAssetDetail = '';
  bool _started = false;
  bool _skipRequested = false;
  String _currentAppVersion = 'unknown';

  AppPreparationState get state => _state;
  DeviceTtsBenchmarkReport? get report => _report;
  String get phaseLabel => _phaseLabel;
  double get progress => _progress;
  double get indicatorProgress => _progress.clamp(0.0, 1.0);
  int get remainingSeconds => _remainingSeconds;
  bool get localTtsEnabled => _report?.enablesLocalTts ?? false;
  int get localTtsThreads => _report?.selectedThreads ?? 2;
  bool get localTtsUnsupported =>
      _report?.status == DeviceTtsCapabilityStatus.unsupported;
  bool get isReady => _state == AppPreparationState.ready;
  bool get countdownActive => _countdownActive;
  bool get showAssetDownloadProgress =>
      _modelAssetDownloadActive || _personaAssetDownloadActive;
  double get assetDownloadProgress => _modelAssetDownloadActive
      ? _modelAssetDownloadFraction
      : _personaAssetDownloadFraction;
  String get assetDownloadProgressText {
    if (_modelAssetDownloadActive && _modelAssetTotalBytes > 0) {
      return '${_formatModelDownloadBytes(_modelAssetDownloadedBytes)} / '
          '${_formatModelDownloadBytes(_modelAssetTotalBytes)}';
    }
    if (_personaAssetDownloadActive) {
      return _personaAssetDetail;
    }
    return '';
  }

  String get assetDownloadDetailText {
    if (_modelAssetDownloadActive) {
      return _modelAssetFileLabel;
    }
    if (_personaAssetDownloadActive) {
      return _personaAssetDetail;
    }
    return '';
  }

  Map<String, String> get liveMetrics =>
      Map<String, String>.unmodifiable(_liveMetrics);

  Future<void> prepare() async {
    if (_started || (!Platform.isAndroid && !Platform.isIOS)) {
      return;
    }
    _started = true;
    _skipRequested = false;
    final SharedPreferences preferences = await SharedPreferences.getInstance();
    final bool forceBenchmark =
        preferences.getBool(forceDeviceBenchmarkNextBootPreferenceKey) == true;
    if (forceBenchmark) {
      await preferences.setBool(
        forceDeviceBenchmarkNextBootPreferenceKey,
        false,
      );
      await preferences.setBool(_runningPreferenceKey, false);
      await preferences.remove(_phasePreferenceKey);
    }
    final DeviceTtsBenchmarkThresholds thresholds =
        await loadDeviceTtsBenchmarkThresholds();
    try {
      final PackageInfo packageInfo = await PackageInfo.fromPlatform();
      _currentAppVersion = '${packageInfo.version}+${packageInfo.buildNumber}';
    } catch (_) {
      // Never trust an old capability report when build identity is unknown.
      _currentAppVersion =
          'unavailable-${DateTime.now().microsecondsSinceEpoch}';
    }
    DevicePerformanceSnapshot snapshot;
    try {
      snapshot = await DevicePerformance.snapshot();
    } catch (error) {
      await _finishWithReport(
        preferences,
        _failureReport(
          status: DeviceTtsCapabilityStatus.unsupported,
          cacheKey: 'device-data-unavailable',
          reason: 'Device capability data could not be read: $error',
        ),
      );
      return;
    }

    final String cacheKey = _cacheKey(snapshot, _currentAppVersion, thresholds);
    final bool previousRunInterrupted =
        !forceBenchmark && preferences.getBool(_runningPreferenceKey) == true;
    final String interruptedPhase =
        preferences.getString(_phasePreferenceKey) ?? 'unknown phase';
    final String? storedJson = preferences.getString(_reportPreferenceKey);
    if (storedJson != null && !forceBenchmark) {
      try {
        final DeviceTtsBenchmarkReport stored =
            DeviceTtsBenchmarkReport.fromJson(
              jsonDecode(storedJson) as Map<String, dynamic>,
            );
        if (stored.cacheKey == cacheKey) {
          if (previousRunInterrupted) {
            await _finishWithReport(
              preferences,
              _interruptedProcessReport(stored, interruptedPhase),
            );
          } else {
            _report = stored;
            _state = AppPreparationState.ready;
            notifyListeners();
          }
          return;
        }
      } catch (_) {
        await preferences.remove(_reportPreferenceKey);
      }
    }

    if (previousRunInterrupted) {
      final bool interruptedDuringDownload = interruptedPhase.contains('asset');
      await _finishWithReport(
        preferences,
        _failureReport(
          status: interruptedDuringDownload
              ? DeviceTtsCapabilityStatus.verificationDeferred
              : DeviceTtsCapabilityStatus.unsupported,
          cacheKey: cacheKey,
          reason: interruptedDuringDownload
              ? 'Voice assets were not fully downloaded on the previous run.'
              : 'The local voice test did not complete on the previous run.',
        ),
      );
      return;
    }

    if (!snapshot.supportsArm64) {
      await _finishWithReport(
        preferences,
        _failureReport(
          status: DeviceTtsCapabilityStatus.unsupported,
          cacheKey: cacheKey,
          reason: 'This device does not provide the required ARM64 runtime.',
        ),
      );
      return;
    }
    if (snapshot.lowRamDevice) {
      await _finishWithReport(
        preferences,
        _failureReport(
          status: DeviceTtsCapabilityStatus.unsupported,
          cacheKey: cacheKey,
          reason: 'This device has insufficient memory for local voices.',
        ),
      );
      return;
    }
    if (snapshot.powerSaveMode ||
        snapshot.thermallyConstrained ||
        snapshot.lowMemory ||
        snapshot.availableMemoryBytes <
            thresholds.minimumAvailableMemoryBytes) {
      await _finishWithReport(
        preferences,
        _failureReport(
          status: DeviceTtsCapabilityStatus.verificationDeferred,
          cacheKey: cacheKey,
          reason: 'The device is hot, low on memory, or in battery saver mode.',
        ),
      );
      return;
    }

    await preferences.setBool(_runningPreferenceKey, true);
    await preferences.setString(_phasePreferenceKey, 'voice asset download');
    _state = AppPreparationState.running;
    _phaseLabel = 'Downloading voice assets';
    _progress = 0.01;
    _remainingSeconds = thresholds.benchmarkBudget.inSeconds;
    _countdownActive = false;
    _modelAssetDownloadActive = true;
    _modelAssetDownloadFraction = 0;
    _modelAssetDownloadedBytes = 0;
    _modelAssetTotalBytes = 0;
    _modelAssetFileLabel = '';
    notifyListeners();

    try {
      await VoiceModelAssetStore.instance.ensureVoiceModelPack(
        onProgress: _updateDownloadProgress,
        shouldCancel: () => _skipRequested,
      );
    } catch (error) {
      if (_skipRequested) {
        _resetAfterSkip();
        return;
      }
      _modelAssetDownloadActive = false;
      await _finishWithReport(
        preferences,
        _failureReport(
          status: DeviceTtsCapabilityStatus.verificationDeferred,
          cacheKey: cacheKey,
          reason: 'Voice assets could not be downloaded: $error',
        ),
      );
      return;
    }
    _modelAssetDownloadActive = false;

    await preferences.setString(_phasePreferenceKey, 'voice benchmark');
    _remainingSeconds = thresholds.benchmarkBudget.inSeconds;
    _countdownActive = true;
    _updateProgress('Checking device compatibility', 0.65);
    _startCountdown();

    final DeviceTtsBenchmarkRunner runner = DeviceTtsBenchmarkRunner();
    _activeRunner = runner;
    try {
      final DeviceTtsBenchmarkReport report = await runner
          .run(
            initialSnapshot: snapshot,
            cacheKey: cacheKey,
            appVersion: _currentAppVersion,
            thresholds: thresholds,
            onVoiceBenchmarkComplete:
                (DeviceTtsBenchmarkReport checkpoint) async {
                  await preferences.setString(
                    _reportPreferenceKey,
                    jsonEncode(checkpoint.toJson()),
                  );
                  await preferences.setString(
                    _phasePreferenceKey,
                    'voice benchmark complete',
                  );
                },
            onProgress: _updateBenchmarkProgress,
            onMetric: _setMetric,
          )
          .timeout(
            thresholds.benchmarkBudget,
            onTimeout: () {
              unawaited(runner.cancel());
              throw TimeoutException(
                'The local voice test exceeded one minute.',
              );
            },
          );
      if (report.enablesLocalTts) {
        final bool prefetchComplete = await _prefetchPersonaAssets();
        if (!prefetchComplete && _skipRequested) {
          _resetAfterSkip();
          return;
        }
      }
      await _finishWithReport(preferences, report);
    } catch (error) {
      if (_skipRequested) {
        _resetAfterSkip();
        return;
      }
      await _finishWithReport(
        preferences,
        _failureReport(
          status: DeviceTtsCapabilityStatus.unsupported,
          cacheKey: cacheKey,
          reason: 'Local voice generation failed: $error',
        ),
      );
    } finally {
      _activeRunner = null;
      _countdownTimer?.cancel();
      await preferences.setBool(_runningPreferenceKey, false);
      await preferences.remove(_phasePreferenceKey);
      _skipRequested = false;
    }
  }

  Future<void> retry() async {
    if ((!Platform.isAndroid && !Platform.isIOS) ||
        _state == AppPreparationState.running) {
      return;
    }
    final SharedPreferences preferences = await SharedPreferences.getInstance();
    await preferences.remove(_reportPreferenceKey);
    await preferences.setBool(_runningPreferenceKey, false);
    await preferences.remove(_phasePreferenceKey);
    _started = false;
    _report = null;
    _liveMetrics.clear();
    _state = AppPreparationState.checking;
    notifyListeners();
    await prepare();
  }

  Future<void> enableTalkRetry() async {
    _skipRequested = true;
    _countdownTimer?.cancel();
    _countdownActive = false;
    await _activeRunner?.cancel();
    final SharedPreferences preferences = await SharedPreferences.getInstance();
    await preferences.remove(_reportPreferenceKey);
    await preferences.setBool(_runningPreferenceKey, false);
    await preferences.remove(_phasePreferenceKey);
    _activeRunner = null;
    _started = false;
    _skipRequested = false;
    _report = null;
    _state = Platform.isAndroid || Platform.isIOS
        ? AppPreparationState.checking
        : AppPreparationState.ready;
    _phaseLabel = 'Checking this device';
    _progress = 0;
    _remainingSeconds = _benchmarkBudget.inSeconds;
    _modelAssetDownloadActive = false;
    _personaAssetDownloadActive = false;
    _liveMetrics.clear();
    notifyListeners();
  }

  Future<void> saveBenchmarkThresholds(
    DeviceTtsBenchmarkThresholds thresholds,
  ) async {
    await saveDeviceTtsBenchmarkThresholds(thresholds);
    await enableTalkRetry();
  }

  Future<void> skipForNow() async {
    _skipRequested = true;
    _countdownTimer?.cancel();
    _countdownActive = false;
    await _activeRunner?.cancel();
    final SharedPreferences preferences = await SharedPreferences.getInstance();
    await preferences.setBool(_runningPreferenceKey, false);
    await preferences.remove(_phasePreferenceKey);
    _resetAfterSkip();
  }

  void continueToApp() {
    _state = AppPreparationState.ready;
    notifyListeners();
  }

  void _resetAfterSkip() {
    _activeRunner = null;
    _started = false;
    _state = AppPreparationState.checking;
    _phaseLabel = 'Checking this device';
    _progress = 0;
    _remainingSeconds = _benchmarkBudget.inSeconds;
    _countdownActive = false;
    _modelAssetDownloadActive = false;
    _personaAssetDownloadActive = false;
    _liveMetrics.clear();
    notifyListeners();
  }

  void _startCountdown() {
    _countdownTimer?.cancel();
    _countdownTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (_remainingSeconds > 0) {
        _remainingSeconds -= 1;
        notifyListeners();
      }
    });
  }

  void _updateProgress(String label, double value) {
    _phaseLabel = label;
    _progress = value.clamp(0.0, 1.0);
    notifyListeners();
  }

  void _updateDownloadProgress(VoiceModelAssetProgress progress) {
    _phaseLabel = progress.message;
    _modelAssetDownloadActive = true;
    _modelAssetDownloadFraction = progress.fraction;
    _modelAssetDownloadedBytes = progress.downloadedBytes;
    _modelAssetTotalBytes = progress.totalBytes;
    _modelAssetFileLabel =
        '${progress.fileIndex}/${progress.fileCount} ${progress.fileName}';
    _progress = 0.02 + (progress.fraction * 0.60);
    _setMetric(
      'voice_assets',
      'Voice assets',
      '${_formatModelDownloadBytes(progress.downloadedBytes)} / '
          '${_formatModelDownloadBytes(progress.totalBytes)}',
      notify: false,
    );
    _setMetric(
      'voice_asset_file',
      progress.cached ? 'Checked file' : 'Downloading file',
      '${progress.fileIndex}/${progress.fileCount} ${progress.fileName}',
      notify: false,
    );
    notifyListeners();
  }

  Future<bool> _prefetchPersonaAssets() async {
    _countdownTimer?.cancel();
    _countdownActive = false;
    _personaAssetDownloadActive = true;
    _personaAssetDownloadFraction = 0;
    _personaAssetDetail = '';
    _phaseLabel = 'Preparing storytellers for Chat';
    _progress = 0.99;
    notifyListeners();
    try {
      final PersonaAssetPrefetchResult
      result = await const PersonaAssetCache().prefetchAll(
        shouldCancel: () => _skipRequested,
        onProgress: (PersonaAssetPrefetchProgress progress) {
          _phaseLabel = progress.message;
          _personaAssetDownloadFraction = progress.fraction;
          _personaAssetDetail = progress.totalAssets <= 0
              ? 'Checking storytellers'
              : '${progress.completedAssets}/${progress.totalAssets} assets';
          _setMetric(
            'persona_assets',
            'Persona assets',
            _personaAssetDetail,
            notify: false,
          );
          notifyListeners();
        },
      );
      _setMetric(
        'persona_assets_ready',
        'Persona assets ready',
        '${result.cachedAssetCount} assets for ${result.personaCount} personas',
        notify: false,
      );
      return true;
    } catch (error) {
      if (_skipRequested) {
        return false;
      }
      _setMetric(
        'persona_assets_ready',
        'Persona assets ready',
        'Deferred: $error',
        notify: false,
      );
      return true;
    } finally {
      _personaAssetDownloadActive = false;
    }
  }

  void _updateBenchmarkProgress(String label, double value) {
    _updateProgress(label, 0.65 + (value.clamp(0.0, 1.0).toDouble() * 0.34));
  }

  void _setMetric(
    String key,
    String label,
    String value, {
    bool notify = true,
  }) {
    _liveMetrics[key] = '$label|$value';
    if (notify) {
      notifyListeners();
    }
  }

  Future<void> _finishWithReport(
    SharedPreferences preferences,
    DeviceTtsBenchmarkReport report,
  ) async {
    _countdownTimer?.cancel();
    _countdownActive = false;
    _report = report;
    _progress = 1;
    _remainingSeconds = 0;
    _phaseLabel = 'StoryVault setup is complete';
    _populateFinalMetrics(report);
    await preferences.setString(
      _reportPreferenceKey,
      jsonEncode(report.toJson()),
    );
    await preferences.setBool(_runningPreferenceKey, false);
    await preferences.remove(_phasePreferenceKey);
    _state = AppPreparationState.result;
    notifyListeners();
  }

  void _populateFinalMetrics(DeviceTtsBenchmarkReport report) {
    _setMetric(
      'tts_first_audio',
      'Voice first audio p95',
      '${report.firstAudioP95Ms.toStringAsFixed(0)} ms',
      notify: false,
    );
    _setMetric(
      'tts_warm_rtf',
      'Voice warm RTF p95',
      report.warmRtfP95.toStringAsFixed(2),
      notify: false,
    );
    _setMetric(
      'tts_sustained_rtf',
      'Voice sustained RTF p95',
      report.sustainedRtfP95.toStringAsFixed(2),
      notify: false,
    );
  }

  DeviceTtsBenchmarkReport _failureReport({
    required DeviceTtsCapabilityStatus status,
    required String cacheKey,
    required String reason,
  }) {
    return DeviceTtsBenchmarkReport(
      status: status,
      cacheKey: cacheKey,
      appVersion: _currentAppVersion,
      reason: reason,
      selectedThreads: 2,
      modelInitializationMs: 0,
      firstAudioP95Ms: 0,
      warmRtfP95: 0,
      sustainedRtfP95: 0,
      thermalDegradation: 0,
      peakProcessMemoryRatio: 0,
      generationFailures: 1,
      completedAt: DateTime.now(),
    );
  }

  DeviceTtsBenchmarkReport _interruptedProcessReport(
    DeviceTtsBenchmarkReport checkpoint,
    String _,
  ) {
    return DeviceTtsBenchmarkReport(
      status: checkpoint.status,
      cacheKey: checkpoint.cacheKey,
      appVersion: checkpoint.appVersion,
      reason: checkpoint.reason,
      selectedThreads: checkpoint.selectedThreads,
      modelInitializationMs: checkpoint.modelInitializationMs,
      firstAudioP95Ms: checkpoint.firstAudioP95Ms,
      warmRtfP95: checkpoint.warmRtfP95,
      sustainedRtfP95: checkpoint.sustainedRtfP95,
      thermalDegradation: checkpoint.thermalDegradation,
      peakProcessMemoryRatio: checkpoint.peakProcessMemoryRatio,
      generationFailures: checkpoint.generationFailures,
      completedAt: DateTime.now(),
    );
  }

  String _cacheKey(
    DevicePerformanceSnapshot snapshot,
    String appVersion,
    DeviceTtsBenchmarkThresholds thresholds,
  ) {
    return <Object>[
      _benchmarkVersion,
      appVersion,
      thresholds.cacheKey,
      pocketTtsModelId,
      pocketTtsRuntimeId,
      snapshot.platform,
      snapshot.buildFingerprint,
      snapshot.sdkInt,
    ].join('|');
  }

  @override
  void dispose() {
    _countdownTimer?.cancel();
    unawaited(_activeRunner?.cancel());
    super.dispose();
  }
}

class DeviceTtsBenchmarkRunner {
  PocketTtsBenchmarkEngine? _engine;
  bool _cancelled = false;
  bool _monitoringMemory = false;
  int _peakProcessPssBytes = 0;

  static const List<String> _firstResponseTexts = <String>[
    'A tiny moonbeam danced across the quiet garden and woke a sleepy star.',
    'Welcome, explorer! Today we can follow a silver comet beyond the clouds.',
    'The little dragon opened its wings and discovered they sparkled like rainbows.',
    'Deep inside the library, a friendly book whispered that an adventure was near.',
  ];

  static const List<String> _sustainedTexts = <String>[
    'Mira stepped onto the glowing bridge and listened carefully. Below her, the river hummed a gentle song, while fireflies drew golden circles in the evening air.',
    'The curious robot found a seed beneath the red dust of Mars. It protected the seed from the cold, gave it one precious drop of water, and waited for a green leaf.',
    'When the old clock struck midnight, every painted animal in the museum stretched, yawned, and climbed down to search for the missing crown before sunrise.',
  ];

  Future<DeviceTtsBenchmarkReport> run({
    required DevicePerformanceSnapshot initialSnapshot,
    required String cacheKey,
    required String appVersion,
    required DeviceTtsBenchmarkThresholds thresholds,
    required Future<void> Function(DeviceTtsBenchmarkReport report)
    onVoiceBenchmarkComplete,
    required void Function(String label, double progress) onProgress,
    required void Function(String key, String label, String value) onMetric,
  }) async {
    _peakProcessPssBytes = initialSnapshot.processPssBytes;
    _monitoringMemory = true;
    unawaited(_monitorMemory());

    final List<int> candidates = initialSnapshot.cpuCores >= 6
        ? const <int>[4, 2]
        : const <int>[2];
    final Map<int, double> candidateLatency = <int, double>{};
    var initializationMs = 0.0;
    var generationFailures = 0;

    try {
      for (var index = 0; index < candidates.length; index += 1) {
        _throwIfCancelled();
        final int threads = candidates[index];
        onProgress(
          'Tuning the voice engine',
          0.10 + (index / candidates.length) * 0.10,
        );
        final PocketTtsBenchmarkEngine engine = PocketTtsBenchmarkEngine();
        await _replaceEngine(engine);
        initializationMs = math.max(
          initializationMs,
          await engine.initialize(numThreads: threads),
        );
        _throwIfCancelled();
        final PocketTtsBenchmarkSample probe = await engine.synthesize(
          _firstResponseTexts.first,
        );
        _throwIfCancelled();
        if (!probe.validAudio) {
          continue;
        } else {
          candidateLatency[threads] = probe.synthesisMilliseconds;
          onMetric(
            'tts_probe',
            'Voice probe',
            '${probe.synthesisMilliseconds.toStringAsFixed(0)} ms',
          );
        }
      }

      if (candidateLatency.isEmpty) {
        throw StateError('PocketTTS did not generate valid benchmark audio.');
      }
      final int selectedThreads = candidateLatency.entries
          .reduce((a, b) => a.value <= b.value ? a : b)
          .key;
      if (_engine == null || candidates.last != selectedThreads) {
        final PocketTtsBenchmarkEngine engine = PocketTtsBenchmarkEngine();
        await _replaceEngine(engine);
        initializationMs = math.max(
          initializationMs,
          await engine.initialize(numThreads: selectedThreads),
        );
        _throwIfCancelled();
        await engine.synthesize(_firstResponseTexts.first);
        _throwIfCancelled();
      }

      final List<PocketTtsBenchmarkSample> shortSamples =
          <PocketTtsBenchmarkSample>[];
      final List<PocketTtsBenchmarkSample> sustainedSamples =
          <PocketTtsBenchmarkSample>[];
      for (var index = 0; index < _firstResponseTexts.length; index += 1) {
        _throwIfCancelled();
        onProgress(
          'Testing quick replies',
          0.22 + (index / _firstResponseTexts.length) * 0.22,
        );
        final PocketTtsBenchmarkSample sample = await _engine!.synthesize(
          _firstResponseTexts[index],
        );
        _throwIfCancelled();
        if (sample.validAudio) {
          shortSamples.add(sample);
          onMetric(
            'tts_quick',
            'Voice quick reply',
            '${sample.synthesisMilliseconds.toStringAsFixed(0)} ms · '
                'RTF ${sample.realtimeFactor.toStringAsFixed(2)}',
          );
        } else {
          generationFailures += 1;
        }
      }
      for (var index = 0; index < _sustainedTexts.length; index += 1) {
        _throwIfCancelled();
        onProgress(
          'Testing a longer conversation',
          0.46 + (index / _sustainedTexts.length) * 0.22,
        );
        final PocketTtsBenchmarkSample sample = await _engine!.synthesize(
          _sustainedTexts[index],
        );
        _throwIfCancelled();
        if (sample.validAudio) {
          sustainedSamples.add(sample);
          onMetric(
            'tts_sustained',
            'Voice sustained RTF',
            sample.realtimeFactor.toStringAsFixed(2),
          );
        } else {
          generationFailures += 1;
        }
      }
      if (shortSamples.length != _firstResponseTexts.length ||
          sustainedSamples.length != _sustainedTexts.length) {
        throw StateError('One or more generated voice samples were invalid.');
      }

      onProgress('Checking sustained voice performance', 0.69);
      final PocketTtsBenchmarkSample finalThermalSample = await _engine!
          .synthesize(_firstResponseTexts.first);
      _throwIfCancelled();
      if (!finalThermalSample.validAudio) {
        generationFailures += 1;
      }

      final DevicePerformanceSnapshot voiceSnapshot =
          await DevicePerformance.snapshot();
      _peakProcessPssBytes = math.max(
        _peakProcessPssBytes,
        voiceSnapshot.processPssBytes,
      );
      final int voicePeakProcessPssBytes = _peakProcessPssBytes;
      final double firstAudioP95Ms = _percentile95(
        shortSamples.map((sample) => sample.synthesisMilliseconds),
      );
      final double warmRtfP95 = _percentile95(
        shortSamples.map((sample) => sample.realtimeFactor),
      );
      final double sustainedRtfP95 = _percentile95(
        sustainedSamples.map((sample) => sample.realtimeFactor),
      );
      final double initialRtf = shortSamples.first.realtimeFactor;
      final double finalRtf = finalThermalSample.realtimeFactor;
      final double thermalDegradation = initialRtf > 0
          ? math.max(0, (finalRtf - initialRtf) / initialRtf)
          : double.infinity;
      final double memoryRatio = initialSnapshot.totalMemoryBytes > 0
          ? voicePeakProcessPssBytes / initialSnapshot.totalMemoryBytes
          : 1;

      onMetric(
        'tts_first_audio',
        'Voice first audio p95',
        '${firstAudioP95Ms.toStringAsFixed(0)} ms',
      );
      onMetric(
        'tts_warm_rtf',
        'Voice warm RTF p95',
        warmRtfP95.toStringAsFixed(2),
      );
      onMetric(
        'tts_sustained_rtf',
        'Voice sustained RTF p95',
        sustainedRtfP95.toStringAsFixed(2),
      );

      final DeviceTtsBenchmarkDecision decision = evaluateDeviceTtsBenchmark(
        firstAudioP95Ms: firstAudioP95Ms,
        warmRtfP95: warmRtfP95,
        sustainedRtfP95: sustainedRtfP95,
        thermalDegradation: thermalDegradation,
        thermallyConstrained: voiceSnapshot.thermallyConstrained,
        peakProcessMemoryRatio: memoryRatio,
        generationFailures: generationFailures,
        thresholds: thresholds,
      );
      final DeviceTtsBenchmarkReport report = DeviceTtsBenchmarkReport(
        status: decision.status,
        cacheKey: cacheKey,
        appVersion: appVersion,
        reason: decision.reason,
        selectedThreads: selectedThreads,
        modelInitializationMs: initializationMs,
        firstAudioP95Ms: firstAudioP95Ms,
        warmRtfP95: warmRtfP95,
        sustainedRtfP95: sustainedRtfP95,
        thermalDegradation: thermalDegradation,
        peakProcessMemoryRatio: memoryRatio,
        generationFailures: generationFailures,
        completedAt: DateTime.now(),
      );
      onProgress('Finishing voice measurements', 0.99);
      await onVoiceBenchmarkComplete(report);
      return report;
    } finally {
      _monitoringMemory = false;
      await _engine?.dispose();
      _engine = null;
    }
  }

  Future<void> cancel() async {
    _cancelled = true;
    _monitoringMemory = false;
    await _engine?.dispose();
    _engine = null;
  }

  Future<void> _replaceEngine(PocketTtsBenchmarkEngine next) async {
    await _engine?.dispose();
    _engine = next;
  }

  Future<void> _monitorMemory() async {
    while (_monitoringMemory && !_cancelled) {
      try {
        final DevicePerformanceSnapshot snapshot =
            await DevicePerformance.snapshot();
        _peakProcessPssBytes = math.max(
          _peakProcessPssBytes,
          snapshot.processPssBytes,
        );
      } catch (_) {
        // A missed telemetry sample must not invalidate otherwise valid audio.
      }
      await Future<void>.delayed(const Duration(milliseconds: 400));
    }
  }

  void _throwIfCancelled() {
    if (_cancelled) {
      throw StateError('PocketTTS benchmark was cancelled.');
    }
  }

  static double _percentile95(Iterable<double> values) {
    final List<double> sorted = values.toList()..sort();
    if (sorted.isEmpty) {
      return double.infinity;
    }
    final int index = ((sorted.length * 0.95).ceil() - 1).clamp(
      0,
      sorted.length - 1,
    );
    return sorted[index];
  }
}
