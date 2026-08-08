import 'package:flutter/services.dart';

class DevicePerformanceSnapshot {
  const DevicePerformanceSnapshot({
    required this.platform,
    required this.supportedAbis,
    required this.sdkInt,
    required this.buildFingerprint,
    required this.totalMemoryBytes,
    required this.availableMemoryBytes,
    required this.processPssBytes,
    required this.memoryClassMb,
    required this.cpuCores,
    required this.lowMemory,
    required this.lowRamDevice,
    required this.powerSaveMode,
    required this.thermalStatus,
  });

  factory DevicePerformanceSnapshot.fromMap(Map<dynamic, dynamic> map) {
    return DevicePerformanceSnapshot(
      platform: map['platform']?.toString() ?? 'unknown',
      supportedAbis: (map['supportedAbis'] as List<dynamic>? ?? const [])
          .map((dynamic value) => value.toString())
          .toList(growable: false),
      sdkInt: (map['sdkInt'] as num?)?.toInt() ?? 0,
      buildFingerprint: map['buildFingerprint']?.toString() ?? 'unknown',
      totalMemoryBytes: (map['totalMemoryBytes'] as num?)?.toInt() ?? 0,
      availableMemoryBytes: (map['availableMemoryBytes'] as num?)?.toInt() ?? 0,
      processPssBytes: (map['processPssBytes'] as num?)?.toInt() ?? 0,
      memoryClassMb: (map['memoryClassMb'] as num?)?.toInt() ?? 0,
      cpuCores: (map['cpuCores'] as num?)?.toInt() ?? 0,
      lowMemory: map['lowMemory'] == true,
      lowRamDevice: map['lowRamDevice'] == true,
      powerSaveMode: map['powerSaveMode'] == true,
      thermalStatus: (map['thermalStatus'] as num?)?.toInt() ?? 0,
    );
  }

  final String platform;
  final List<String> supportedAbis;
  final int sdkInt;
  final String buildFingerprint;
  final int totalMemoryBytes;
  final int availableMemoryBytes;
  final int processPssBytes;
  final int memoryClassMb;
  final int cpuCores;
  final bool lowMemory;
  final bool lowRamDevice;
  final bool powerSaveMode;
  final int thermalStatus;

  bool get supportsArm64 =>
      supportedAbis.contains('arm64-v8a') || supportedAbis.contains('arm64');

  // Android PowerManager.THERMAL_STATUS_SEVERE.
  bool get thermallyConstrained => thermalStatus >= 3;
}

class DevicePerformance {
  static const MethodChannel _channel = MethodChannel(
    'storyvault/device_performance',
  );

  static Future<DevicePerformanceSnapshot> snapshot() async {
    final Object? value = await _channel.invokeMethod<Object?>('snapshot');
    if (value is! Map) {
      throw StateError('Device performance data is unavailable.');
    }
    return DevicePerformanceSnapshot.fromMap(value);
  }
}
