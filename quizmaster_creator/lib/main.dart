import 'package:flutter/material.dart';

import 'src/app.dart';
import 'src/state/app_controller.dart';
import 'src/storage/settings_store.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final controller = AppController(settingsStore: SecureSettingsStore());
  await controller.initialize();
  runApp(QuizmasterCreatorApp(controller: controller));
}
