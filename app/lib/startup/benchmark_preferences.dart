import 'package:shared_preferences/shared_preferences.dart';

const String forceDeviceBenchmarkNextBootPreferenceKey =
    'storyvault_force_device_benchmark_next_boot_v1';

Future<bool> forceDeviceBenchmarkOnNextBoot() async {
  final SharedPreferences preferences = await SharedPreferences.getInstance();
  return preferences.getBool(forceDeviceBenchmarkNextBootPreferenceKey) ??
      false;
}

Future<void> setForceDeviceBenchmarkOnNextBoot(bool enabled) async {
  final SharedPreferences preferences = await SharedPreferences.getInstance();
  await preferences.setBool(forceDeviceBenchmarkNextBootPreferenceKey, enabled);
}
