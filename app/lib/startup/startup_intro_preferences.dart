import 'package:shared_preferences/shared_preferences.dart';

const String _showStartupIntroNextBootKey =
    'storyvault_show_startup_intro_next_boot_v1';

Future<bool> showStartupIntroOnNextBoot() async {
  final SharedPreferences preferences = await SharedPreferences.getInstance();
  return preferences.getBool(_showStartupIntroNextBootKey) ?? false;
}

Future<void> setShowStartupIntroOnNextBoot(bool enabled) async {
  final SharedPreferences preferences = await SharedPreferences.getInstance();
  await preferences.setBool(_showStartupIntroNextBootKey, enabled);
}

Future<bool> consumeStartupIntroOnNextBoot() async {
  final SharedPreferences preferences = await SharedPreferences.getInstance();
  final bool enabled =
      preferences.getBool(_showStartupIntroNextBootKey) ?? false;
  if (enabled) {
    await preferences.setBool(_showStartupIntroNextBootKey, false);
  }
  return enabled;
}
