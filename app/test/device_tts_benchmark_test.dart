import 'package:flutter_test/flutter_test.dart';
import 'package:sunshine_app/startup/app_preparation.dart';

void main() {
  test('premium local TTS thresholds pass at their inclusive limits', () {
    final DeviceTtsBenchmarkDecision decision = evaluateDeviceTtsBenchmark(
      firstAudioP95Ms: 1500,
      warmRtfP95: 0.80,
      sustainedRtfP95: 0.85,
      thermalDegradation: 0.35,
      thermallyConstrained: false,
      peakProcessMemoryRatio: 0.25,
      generationFailures: 0,
    );

    expect(decision.status, DeviceTtsCapabilityStatus.localPreferred);
  });

  test('any failed production threshold disables local TTS', () {
    final DeviceTtsBenchmarkDecision decision = evaluateDeviceTtsBenchmark(
      firstAudioP95Ms: 9999,
      warmRtfP95: 0.81,
      sustainedRtfP95: 0.86,
      thermalDegradation: 0.36,
      thermallyConstrained: true,
      peakProcessMemoryRatio: 0.26,
      generationFailures: 1,
    );

    expect(decision.status, DeviceTtsCapabilityStatus.unsupported);
    expect(decision.reason, isNot(contains('first audio')));
    expect(decision.reason, contains('memory'));
    expect(decision.reason, contains('generation failed'));
  });

  test('first generated chunk latency is diagnostic only', () {
    final DeviceTtsBenchmarkDecision decision = evaluateDeviceTtsBenchmark(
      firstAudioP95Ms: 5000,
      warmRtfP95: 0.30,
      sustainedRtfP95: 0.40,
      thermalDegradation: 0.10,
      thermallyConstrained: false,
      peakProcessMemoryRatio: 0.15,
      generationFailures: 0,
    );

    expect(decision.status, DeviceTtsCapabilityStatus.localPreferred);
  });

  test('custom benchmark gates can relax compatibility decisions', () {
    final DeviceTtsBenchmarkThresholds relaxed = deviceTtsBenchmarkThresholds
        .copyWith(
          maximumFirstAudioP95Ms: 2200,
          maximumWarmRtfP95: 0.85,
          maximumSustainedRtfP95: 0.95,
          maximumThermalDegradation: 0.50,
          maximumProcessMemoryRatio: 0.40,
        );

    final DeviceTtsBenchmarkDecision decision = evaluateDeviceTtsBenchmark(
      firstAudioP95Ms: 1900,
      warmRtfP95: 0.80,
      sustainedRtfP95: 0.90,
      thermalDegradation: 0.45,
      thermallyConstrained: false,
      peakProcessMemoryRatio: 0.35,
      generationFailures: 0,
      thresholds: relaxed,
    );

    expect(decision.status, DeviceTtsCapabilityStatus.localPreferred);
  });

  test('benchmark threshold json survives persistence shape round trip', () {
    final DeviceTtsBenchmarkThresholds source = deviceTtsBenchmarkThresholds
        .copyWith(
          maximumFirstAudioP95Ms: 2100,
          maximumWarmRtfP95: 0.80,
          maximumSustainedRtfP95: 0.90,
          maximumThermalDegradation: 0.45,
          maximumProcessMemoryRatio: 0.35,
          maximumGenerationFailures: 1,
          minimumAvailableMemoryBytes: 384 * 1024 * 1024,
        );

    final DeviceTtsBenchmarkThresholds restored =
        DeviceTtsBenchmarkThresholds.fromJson(source.toJson());

    expect(restored.maximumFirstAudioP95Ms, 2100);
    expect(restored.maximumWarmRtfP95, 0.80);
    expect(restored.maximumSustainedRtfP95, 0.90);
    expect(restored.maximumThermalDegradation, 0.45);
    expect(restored.maximumProcessMemoryRatio, 0.35);
    expect(restored.maximumGenerationFailures, 1);
    expect(restored.minimumAvailableMemoryBytes, 384 * 1024 * 1024);
  });

  test('benchmark threshold json clamps unsafe values', () {
    final DeviceTtsBenchmarkThresholds restored =
        DeviceTtsBenchmarkThresholds.fromJson(<String, dynamic>{
          'maximum_first_audio_p95_ms': 999999,
          'maximum_warm_rtf_p95': 9,
          'maximum_sustained_rtf_p95': 9,
          'maximum_thermal_degradation': 9,
          'maximum_process_memory_ratio': 9,
          'maximum_generation_failures': 99,
          'minimum_available_memory_bytes': 64,
        });

    expect(restored.maximumFirstAudioP95Ms, 6000);
    expect(restored.maximumWarmRtfP95, 1.50);
    expect(restored.maximumSustainedRtfP95, 2.00);
    expect(restored.maximumThermalDegradation, 1.00);
    expect(restored.maximumProcessMemoryRatio, 0.80);
    expect(restored.maximumGenerationFailures, 3);
    expect(restored.minimumAvailableMemoryBytes, 128 * 1024 * 1024);
  });

  test('benchmark report survives persistence round trip', () {
    final DeviceTtsBenchmarkReport source = DeviceTtsBenchmarkReport(
      status: DeviceTtsCapabilityStatus.localPreferred,
      cacheKey: 'device|model|runtime',
      appVersion: '1.0.0+1',
      reason: 'Local cloned-voice generation passed.',
      selectedThreads: 4,
      modelInitializationMs: 830,
      firstAudioP95Ms: 940,
      warmRtfP95: 0.42,
      sustainedRtfP95: 0.58,
      thermalDegradation: 0.12,
      peakProcessMemoryRatio: 0.18,
      generationFailures: 0,
      completedAt: DateTime.utc(2026, 7, 17, 12),
    );

    final DeviceTtsBenchmarkReport restored = DeviceTtsBenchmarkReport.fromJson(
      source.toJson(),
    );

    expect(restored.status, source.status);
    expect(restored.cacheKey, source.cacheKey);
    expect(restored.appVersion, '1.0.0+1');
    expect(restored.selectedThreads, 4);
    expect(restored.firstAudioP95Ms, 940);
    expect(restored.completedAt, source.completedAt);
  });
}
